//! Bounded PCM transport from one realtime producer to the frame consumer.

use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

use lunette_compositor::protocol::PipeWireGeneration;
use rtrb::{Consumer, Producer, RingBuffer};

use crate::audio::AudioFormat;

pub const TRANSPORT_FRAMES: usize = 12_000;
pub const TRANSPORT_PACKETS: usize = 256;
pub const PUBLICATION_PACKETS: usize = 64;

/// A local sample counter, not a device timestamp or a presentation timestamp.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SampleTiming {
    pub generation: PipeWireGeneration,
    pub sequence: u64,
    pub first_frame: u64,
}

#[derive(Clone, Debug)]
pub struct AudioBlock {
    pub timing: SampleTiming,
    pub frames: usize,
    pub gap_packets: u64,
    pub gap_frames: u64,
    pub samples: Arc<[f32]>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TransportLoss {
    pub packets: u64,
    pub frames: u64,
    pub malformed_packets: u64,
}

impl TransportLoss {
    pub(crate) fn combined(self, other: Self) -> Self {
        Self {
            packets: self.packets.saturating_add(other.packets),
            frames: self.frames.saturating_add(other.frames),
            malformed_packets: self
                .malformed_packets
                .saturating_add(other.malformed_packets),
        }
    }
}

/// A borrowed interleaved F32LE SPA data plane. Offsets are bytes, not samples.
pub struct PcmPacket<'a> {
    pub bytes: &'a [u8],
    pub offset: usize,
    pub size: usize,
    pub stride: i32,
    pub format: Option<AudioFormat>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PacketResult {
    Accepted,
    Malformed,
    Overrun,
    IdentifierExhausted,
}

/// Owns the only producer. All storage is allocated before the callback starts.
pub struct AudioProducer {
    queue: Producer<QueueEntry>,
    generation: PipeWireGeneration,
    sequence: u64,
    first_frame: u64,
    gap: TransportLoss,
    loss: Arc<LossCounters>,
    consumed: Arc<Consumed>,
    published_frames: u64,
    published_packets: u64,
    exhausted: bool,
    total_loss: TransportLoss,
}

pub struct AudioConsumer {
    queue: Consumer<QueueEntry>,
    loss: Arc<LossCounters>,
    consumed: Arc<Consumed>,
    discarded: TransportLoss,
    gap: TransportLoss,
}

/// Frozen packet occupancy. A producer can replenish without extending this cutoff.
pub struct AudioCutoff {
    packets: Vec<PacketMeta>,
    pub queued_packets: usize,
    pub queued_frames: usize,
    pub loss: TransportLoss,
}

pub fn audio_transport(generation: PipeWireGeneration) -> (AudioProducer, AudioConsumer) {
    let (queue_tx, queue_rx) = RingBuffer::new(TRANSPORT_FRAMES + TRANSPORT_PACKETS);
    let loss = Arc::new(LossCounters::default());
    let consumed = Arc::new(Consumed::default());
    (
        AudioProducer {
            queue: queue_tx,
            consumed: consumed.clone(),
            published_frames: 0,
            published_packets: 0,
            exhausted: false,
            total_loss: TransportLoss::default(),
            generation,
            sequence: 0,
            first_frame: 0,
            gap: TransportLoss::default(),
            loss: loss.clone(),
        },
        AudioConsumer {
            queue: queue_rx,
            loss,
            consumed,
            discarded: TransportLoss::default(),
            gap: TransportLoss::default(),
        },
    )
}

impl AudioProducer {
    /// No allocation, locks, logging, waiting, or partial packet publication.
    pub fn push(&mut self, packet: PcmPacket<'_>) -> PacketResult {
        let frames = packet.size / 8;
        let timing = SampleTiming {
            generation: self.generation,
            sequence: self.sequence,
            first_frame: self.first_frame,
        };
        let counters = self
            .sequence
            .checked_add(1)
            .zip(self.first_frame.checked_add(frames as u64))
            .zip(self.published_packets.checked_add(1))
            .zip(self.published_frames.checked_add(frames as u64));
        if self.exhausted || counters.is_none() {
            self.exhausted = true;
            self.drop_packet(frames, false);
            return PacketResult::IdentifierExhausted;
        }
        self.sequence += 1;
        self.first_frame += frames as u64;
        // The finite-sample scan is bounded even for a malformed oversized plane.
        if frames > TRANSPORT_FRAMES {
            self.drop_packet(frames, false);
            return PacketResult::Overrun;
        }
        let Some(bytes) = valid_bytes(&packet) else {
            self.drop_packet(frames, true);
            return PacketResult::Malformed;
        };
        let queued_frames = self
            .published_frames
            .saturating_sub(self.consumed.frames.load(Ordering::Acquire));
        let queued_packets = self
            .published_packets
            .saturating_sub(self.consumed.packets.load(Ordering::Acquire));
        if frames > TRANSPORT_FRAMES
            || queued_frames + frames as u64 > TRANSPORT_FRAMES as u64
            || queued_packets >= TRANSPORT_PACKETS as u64
        {
            self.drop_packet(frames, false);
            return PacketResult::Overrun;
        }
        let Ok(mut packet_chunk) = self.queue.write_chunk(frames + 1) else {
            self.drop_packet(frames, false);
            return PacketResult::Overrun;
        };
        let (one, two) = packet_chunk.as_mut_slices();
        let mut entries = one.iter_mut().chain(two);
        if let Some(header) = entries.next() {
            *header = QueueEntry::Header(PacketMeta {
                timing,
                frames,
                gap_packets: self.gap.packets,
                gap_frames: self.gap.frames,
            });
        }
        for (entry, raw) in entries.zip(bytes.as_chunks::<8>().0) {
            *entry = QueueEntry::Frame([
                f32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]),
                f32::from_le_bytes([raw[4], raw[5], raw[6], raw[7]]),
            ]);
        }
        packet_chunk.commit_all();
        self.published_frames += frames as u64;
        self.published_packets += 1;
        self.gap = TransportLoss::default();
        PacketResult::Accepted
    }

    fn drop_packet(&mut self, frames: usize, malformed: bool) {
        self.gap.packets = self.gap.packets.saturating_add(1);
        self.gap.frames = self.gap.frames.saturating_add(frames as u64);
        self.total_loss.packets = self.total_loss.packets.saturating_add(1);
        self.total_loss.frames = self.total_loss.frames.saturating_add(frames as u64);
        if malformed {
            self.total_loss.malformed_packets = self.total_loss.malformed_packets.saturating_add(1);
        }
        // Only the producer writes these totals. No wrapping fetch_add or CAS loop.
        self.loss
            .packets
            .store(self.total_loss.packets, Ordering::Relaxed);
        self.loss
            .frames
            .store(self.total_loss.frames, Ordering::Relaxed);
        self.loss
            .malformed
            .store(self.total_loss.malformed_packets, Ordering::Relaxed);
    }
}

impl AudioConsumer {
    /// Discards the complete current prefix without allocating PCM blocks. Later
    /// producer writes remain queued for the next cutoff. Discards are explicit loss.
    pub fn discard(&mut self) -> TransportLoss {
        let slots = self.queue.slots();
        let mut discarded = TransportLoss::default();
        if let Ok(chunk) = self.queue.read_chunk(slots) {
            let (one, two) = chunk.as_slices();
            for entry in one.iter().chain(two) {
                if let QueueEntry::Header(packet) = entry {
                    discarded.packets = discarded.packets.saturating_add(1);
                    discarded.frames = discarded.frames.saturating_add(packet.frames as u64);
                    self.gap.packets = self.gap.packets.saturating_add(packet.gap_packets);
                    self.gap.frames = self.gap.frames.saturating_add(packet.gap_frames);
                }
            }
            chunk.commit_all();
            self.consumed
                .frames
                .fetch_add(discarded.frames, Ordering::Release);
            self.consumed
                .packets
                .fetch_add(discarded.packets, Ordering::Release);
        }
        self.discarded = self.discarded.combined(discarded);
        self.gap = self.gap.combined(discarded);
        discarded
    }
    pub(crate) fn pending_gap(&self) -> TransportLoss {
        self.gap
    }
    pub fn snapshot(&mut self) -> AudioCutoff {
        let slots = self.queue.slots();
        let mut packets = Vec::with_capacity(PUBLICATION_PACKETS);
        let mut queued_frames = 0;
        let mut queued_packets = 0;
        if let Ok(chunk) = self.queue.read_chunk(slots) {
            let (one, two) = chunk.as_slices();
            for entry in one.iter().chain(two) {
                if let QueueEntry::Header(packet) = entry {
                    queued_packets += 1;
                    queued_frames += packet.frames;
                    if packets.len() < PUBLICATION_PACKETS {
                        packets.push(*packet);
                    }
                }
            }
        }
        AudioCutoff {
            packets,
            queued_packets,
            queued_frames,
            loss: self.loss.snapshot().combined(self.discarded),
        }
    }

    /// Consumes only the frozen prefix and rejects blocks from another connection.
    pub fn drain(
        &mut self,
        cutoff: AudioCutoff,
        generation: PipeWireGeneration,
    ) -> Vec<AudioBlock> {
        let mut blocks = Vec::with_capacity(cutoff.packets.len());
        for packet in cutoff.packets {
            let Ok(QueueEntry::Header(front)) = self.queue.peek() else {
                break;
            };
            if front.timing != packet.timing {
                break;
            }
            let Ok(chunk) = self.queue.read_chunk(packet.frames + 1) else {
                break;
            };
            let (one, two) = chunk.as_slices();
            let frames = one.iter().chain(two).skip(1);
            if frames
                .clone()
                .any(|entry| !matches!(entry, QueueEntry::Frame(_)))
            {
                break;
            }
            if packet.timing.generation == generation {
                let mut samples = Vec::with_capacity(packet.frames * 2);
                for entry in frames {
                    if let QueueEntry::Frame(frame) = entry {
                        samples.extend_from_slice(frame);
                    }
                }
                blocks.push(AudioBlock {
                    timing: packet.timing,
                    frames: packet.frames,
                    gap_packets: packet.gap_packets.saturating_add(self.gap.packets),
                    gap_frames: packet.gap_frames.saturating_add(self.gap.frames),
                    samples: samples.into(),
                });
                self.gap = TransportLoss::default();
            } else {
                let discarded = TransportLoss {
                    packets: 1,
                    frames: packet.frames as u64,
                    malformed_packets: 0,
                };
                self.discarded = self.discarded.combined(discarded);
                self.gap = self.gap.combined(TransportLoss {
                    packets: discarded.packets.saturating_add(packet.gap_packets),
                    frames: discarded.frames.saturating_add(packet.gap_frames),
                    malformed_packets: 0,
                });
            }
            chunk.commit_all();
            self.consumed
                .frames
                .fetch_add(packet.frames as u64, Ordering::Release);
            self.consumed.packets.fetch_add(1, Ordering::Release);
        }
        blocks
    }
}

#[derive(Clone, Copy, Default)]
enum QueueEntry {
    #[default]
    Empty,
    Header(PacketMeta),
    Frame([f32; 2]),
}

#[derive(Default)]
struct Consumed {
    frames: AtomicU64,
    packets: AtomicU64,
}

fn valid_bytes<'a>(packet: &PcmPacket<'a>) -> Option<&'a [u8]> {
    if packet.format != Some(AudioFormat::STEREO_F32_48K)
        || packet.stride != 8
        || packet.size == 0
        || !packet.size.is_multiple_of(8)
        || !packet.offset.is_multiple_of(4)
    {
        return None;
    }
    let end = packet.offset.checked_add(packet.size)?;
    let bytes = packet.bytes.get(packet.offset..end)?;
    if bytes
        .as_chunks::<4>()
        .0
        .iter()
        .any(|raw| !f32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]).is_finite())
    {
        return None;
    }
    Some(bytes)
}

#[derive(Clone, Copy)]
struct PacketMeta {
    timing: SampleTiming,
    frames: usize,
    gap_packets: u64,
    gap_frames: u64,
}

impl Default for PacketMeta {
    fn default() -> Self {
        Self {
            timing: SampleTiming {
                generation: PipeWireGeneration(0),
                sequence: 0,
                first_frame: 0,
            },
            frames: 0,
            gap_packets: 0,
            gap_frames: 0,
        }
    }
}

#[derive(Default)]
struct LossCounters {
    packets: AtomicU64,
    frames: AtomicU64,
    malformed: AtomicU64,
}

impl LossCounters {
    fn snapshot(&self) -> TransportLoss {
        TransportLoss {
            packets: self.packets.load(Ordering::Relaxed),
            frames: self.frames.load(Ordering::Relaxed),
            malformed_packets: self.malformed.load(Ordering::Relaxed),
        }
    }
}

#[cfg(test)]
mod stress_tests;

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "tests report failures through expectations"
)]
mod tests {
    use super::*;

    fn packet(bytes: &[u8]) -> PcmPacket<'_> {
        PcmPacket {
            bytes,
            offset: 0,
            size: bytes.len(),
            stride: 8,
            format: Some(AudioFormat::STEREO_F32_48K),
        }
    }

    #[test]
    fn audio_transport_overrun_and_format() {
        let (mut tx, mut rx) = audio_transport(PipeWireGeneration(2));
        let full = vec![0; TRANSPORT_FRAMES * 8];
        assert_eq!(tx.push(packet(&full)), PacketResult::Accepted);
        assert_eq!(tx.push(packet(&[0; 16])), PacketResult::Overrun);
        let cutoff = rx.snapshot();
        assert_eq!(cutoff.loss.frames, 2);
        assert_eq!(
            rx.drain(cutoff, PipeWireGeneration(2))[0].frames,
            TRANSPORT_FRAMES
        );
        assert_eq!(tx.push(packet(&[0; 8])), PacketResult::Accepted);
        let cutoff = rx.snapshot();
        let blocks = rx.drain(cutoff, PipeWireGeneration(2));
        assert_eq!(blocks[0].gap_frames, 2);
        assert_eq!(blocks[0].timing.first_frame, 12_002);
        for (offset, size, stride, format) in [
            (usize::MAX, 8, 8, Some(AudioFormat::STEREO_F32_48K)),
            (1, 8, 8, Some(AudioFormat::STEREO_F32_48K)),
            (0, 7, 8, Some(AudioFormat::STEREO_F32_48K)),
            (0, 8, -8, Some(AudioFormat::STEREO_F32_48K)),
            (0, 8, 8, None),
        ] {
            assert_eq!(
                tx.push(PcmPacket {
                    bytes: &[0; 8],
                    offset,
                    size,
                    stride,
                    format
                }),
                PacketResult::Malformed
            );
        }
        let mut nonfinite = [0; 8];
        nonfinite[..4].copy_from_slice(&f32::NAN.to_le_bytes());
        assert_eq!(tx.push(packet(&nonfinite)), PacketResult::Malformed);
        assert_eq!(rx.snapshot().queued_packets, 0);
        assert_eq!(tx.push(packet(&[0; 8])), PacketResult::Accepted);
        let cutoff = rx.snapshot();
        assert!(rx.drain(cutoff, PipeWireGeneration(3)).is_empty());
        assert_eq!(rx.snapshot().queued_packets, 0);
    }

    #[test]
    fn cutoff_is_immutable_under_concurrent_replenishment() {
        let (mut tx, mut rx) = audio_transport(PipeWireGeneration(1));
        for _ in 0..64 {
            assert_eq!(tx.push(packet(&[0; 8])), PacketResult::Accepted);
        }
        let cutoff = rx.snapshot();
        let producer = std::thread::spawn(move || {
            for _ in 0..128 {
                assert_eq!(tx.push(packet(&[0; 8])), PacketResult::Accepted);
            }
            tx
        });
        let blocks = rx.drain(cutoff, PipeWireGeneration(1));
        let _tx = producer.join().expect("producer joined");
        assert_eq!(blocks.len(), 64);
        assert_eq!(rx.snapshot().queued_packets, 128);
    }

    #[test]
    fn packet_metadata_is_bounded_and_offset_is_honoured() {
        let (mut tx, mut rx) = audio_transport(PipeWireGeneration(1));
        for _ in 0..TRANSPORT_PACKETS {
            assert_eq!(tx.push(packet(&[0; 8])), PacketResult::Accepted);
        }
        assert_eq!(tx.push(packet(&[0; 8])), PacketResult::Overrun);
        for _ in 0..4 {
            let cutoff = rx.snapshot();
            assert_eq!(rx.drain(cutoff, PipeWireGeneration(1)).len(), 64);
        }
        let bytes = [99, 99, 99, 99, 0, 0, 128, 63, 0, 0, 0, 64];
        assert_eq!(
            tx.push(PcmPacket {
                bytes: &bytes,
                offset: 4,
                size: 8,
                stride: 8,
                format: Some(AudioFormat::STEREO_F32_48K)
            }),
            PacketResult::Accepted
        );
        let cutoff = rx.snapshot();
        assert_eq!(
            rx.drain(cutoff, PipeWireGeneration(1))[0].samples.as_ref(),
            &[1.0, 2.0]
        );
    }
}
