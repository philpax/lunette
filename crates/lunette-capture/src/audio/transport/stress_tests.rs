use std::time::{Duration, Instant};

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
fn sustained_spsc_preserves_sample_order_and_accounts_for_every_loss() {
    const ATTEMPTS: u64 = 100_000;
    let (mut producer, mut consumer) = audio_transport(PipeWireGeneration(7));
    // Guarantee an initial overflow independent of thread scheduling.
    for _ in 0..TRANSPORT_PACKETS {
        assert_eq!(producer.push(packet(&[0; 8])), PacketResult::Accepted);
    }
    let worker = std::thread::spawn(move || {
        let mut accepted = TRANSPORT_PACKETS as u64;
        for _ in 0..ATTEMPTS {
            let sequence = producer.sequence;
            let value = sequence as f32;
            let mut bytes = [0; 8];
            bytes[..4].copy_from_slice(&value.to_le_bytes());
            bytes[4..].copy_from_slice(&(-value).to_le_bytes());
            if producer.push(packet(&bytes)) == PacketResult::Accepted {
                accepted += 1;
            }
            if sequence.is_multiple_of(16) {
                std::thread::yield_now();
            }
        }
        (producer, accepted)
    });
    let mut count = 0_u64;
    let mut previous = None;
    let mut gaps = 0_u64;
    let mut check = |blocks: Vec<AudioBlock>| {
        assert!(blocks.len() <= PUBLICATION_PACKETS);
        for block in blocks {
            if let Some(last) = previous {
                assert_eq!(block.timing.sequence - last - 1, block.gap_packets);
            }
            if block.timing.sequence >= TRANSPORT_PACKETS as u64 {
                assert_eq!(
                    block.samples.as_ref(),
                    &[
                        block.timing.sequence as f32,
                        -(block.timing.sequence as f32)
                    ]
                );
            }
            assert_eq!(block.timing.first_frame, block.timing.sequence);
            assert_eq!(block.gap_frames, block.gap_packets);
            gaps += block.gap_packets;
            previous = Some(block.timing.sequence);
            count += 1;
        }
    };
    while !worker.is_finished() {
        let cutoff = consumer.snapshot();
        check(consumer.drain(cutoff, PipeWireGeneration(7)));
        std::thread::yield_now();
    }
    let (mut producer, accepted) = worker.join().unwrap_or_else(|_| unreachable!());
    while consumer.snapshot().queued_packets > 0 {
        let cutoff = consumer.snapshot();
        check(consumer.drain(cutoff, PipeWireGeneration(7)));
    }
    // Publish a final packet so trailing dropped packets have an explicit gap.
    assert_eq!(producer.push(packet(&[0; 8])), PacketResult::Accepted);
    let cutoff = consumer.snapshot();
    let loss = cutoff.loss;
    let final_block = consumer
        .drain(cutoff, PipeWireGeneration(7))
        .pop()
        .unwrap_or_else(|| unreachable!());
    assert_eq!(
        final_block.timing.sequence - previous.unwrap_or(0) - 1,
        final_block.gap_packets
    );
    gaps += final_block.gap_packets;
    assert_eq!(count, accepted);
    assert_eq!(accepted + loss.packets, ATTEMPTS + TRANSPORT_PACKETS as u64);
    assert_eq!(gaps, loss.packets);
    assert!(loss.packets > 0);
}

#[test]
fn continuously_replenishing_producer_cannot_extend_any_frozen_prefix() {
    use std::sync::atomic::{AtomicBool, AtomicU64};
    let (mut producer, mut consumer) = audio_transport(PipeWireGeneration(1));
    for _ in 0..TRANSPORT_PACKETS {
        assert_eq!(producer.push(packet(&[0; 8])), PacketResult::Accepted);
    }
    let running = Arc::new(AtomicBool::new(true));
    let stopped = running.clone();
    let progress = Arc::new(AtomicU64::new(0));
    let produced = progress.clone();
    let worker = std::thread::spawn(move || {
        while running.load(Ordering::Acquire) {
            let _ = producer.push(packet(&[0; 8]));
            produced.fetch_add(1, Ordering::Release);
            std::thread::yield_now();
        }
    });
    // The drains overlap a producer that is running: at least 500 of them, continuing until the producer has pushed
    // while they run, which a loaded machine can delay past the first 500.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut drains = 0;
    while drains < 500 || progress.load(Ordering::Acquire) == 0 {
        assert!(Instant::now() < deadline, "the producer made no progress");
        drains += 1;
        let cutoff = consumer.snapshot();
        let expected: Vec<_> = cutoff.packets.iter().map(|meta| meta.timing).collect();
        let blocks = consumer.drain(cutoff, PipeWireGeneration(1));
        assert_eq!(
            blocks.iter().map(|block| block.timing).collect::<Vec<_>>(),
            expected
        );
        assert!(blocks.len() <= PUBLICATION_PACKETS);
        std::thread::yield_now();
    }
    stopped.store(false, Ordering::Release);
    worker.join().unwrap_or_else(|_| unreachable!());
}

#[test]
fn identity_exhaustion_is_terminal_and_loss_counters_never_wrap() {
    for field in 0..4 {
        let (mut producer, mut consumer) = audio_transport(PipeWireGeneration(1));
        match field {
            0 => producer.sequence = u64::MAX,
            1 => producer.first_frame = u64::MAX,
            2 => producer.published_packets = u64::MAX,
            _ => producer.published_frames = u64::MAX,
        }
        producer.total_loss = TransportLoss {
            packets: u64::MAX - 1,
            frames: u64::MAX - 1,
            malformed_packets: 0,
        };
        assert_eq!(
            producer.push(packet(&[0; 8])),
            PacketResult::IdentifierExhausted
        );
        assert_eq!(
            producer.push(packet(&[0; 8])),
            PacketResult::IdentifierExhausted
        );
        assert_eq!(consumer.snapshot().loss.packets, u64::MAX);
        assert_eq!(consumer.snapshot().loss.frames, u64::MAX);
        assert_eq!(consumer.snapshot().queued_packets, 0);
    }
}

#[test]
fn oversized_packet_is_rejected_before_finite_sample_scan() {
    let (mut producer, _) = audio_transport(PipeWireGeneration(1));
    let mut bytes = vec![0; (TRANSPORT_FRAMES + 1) * 8];
    bytes[..4].copy_from_slice(&f32::NAN.to_le_bytes());
    assert_eq!(producer.push(packet(&bytes)), PacketResult::Overrun);
}
