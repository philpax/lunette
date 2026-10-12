//! Linux-only: non-routing audio readers and immutable native PCM blocks exposed to Lua.

use std::{cell::Cell, rc::Rc, sync::Arc};

use lunette_capture::audio::{
    AttributionProvenance, AudioBlock as CapturedBlock, AudioFormat, CaptureState, Source,
    UnavailableReason,
};
use mlua::{
    Buffer, ErrorContext, FromLua, IntoLua, Lua, Table, UserData, UserDataFields, UserDataMethods,
    UserDataRef, Value,
};

use crate::{
    audio::{AudioCaptureId, AudioSnapshot as CapturedSnapshot},
    control::wire::HandleKind,
    lua::{
        LuaTexture, Process, Session,
        declarations::{
            AliasSpec, Aliased, Described, HandleSpec, NullTexture, Parameter, Surface, Type,
            Typed, add_fields, add_methods, handle,
        },
    },
};

/// One independent reader of a source shared by the session's capture registry.
#[derive(Debug)]
pub(crate) struct AudioCapture<T> {
    id: AudioCaptureId,
    source: Source,
    session: Rc<Session<T>>,
    closed: Cell<bool>,
}

impl<T> PartialEq for AudioCapture<T> {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id && Rc::ptr_eq(&self.session, &other.session)
    }
}

impl<T> AudioCapture<T> {
    fn publication(&self) -> Arc<CapturedSnapshot> {
        if !self.closed.get()
            && let Some(snapshot) = self.session.audio().snapshot(self.id)
        {
            return snapshot;
        }
        Arc::new(CapturedSnapshot {
            source: self.source,
            state: CaptureState::Ended,
            frame_generation: self.session.generation().get(),
            blocks: Arc::from([]),
        })
    }

    fn close(&self) {
        if !self.closed.replace(true) {
            self.session.audio().close(self.id);
        }
    }
}

handle! {
    /// An independent non-routing audio reader. Close it explicitly when its owner releases it;
    /// collecting the userdata does not close the reader.
    AudioCapture<T: LuaTexture> = HandleKind::AudioCapture;

    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    /// True after close or a terminal source outcome. Starting, idle, and unavailable remain live.
    field dead(_lua, this) -> bool {
        Ok(matches!(this.publication().state, CaptureState::Ended))
    }

    /// The immutable publication for this frame. Repeated reads do not consume blocks.
    method snapshot(_lua, this) -> AudioSnapshot<T> {
        Ok(AudioSnapshot { publication: this.publication(), session: Rc::clone(&this.session) })
    }

    /// Releases this reader once. Other readers of the same source remain open.
    method close(_lua, this) -> () {
        this.close();
        Ok(())
    }
}

/// A closed source descriptor; no raw PID or application label selects a source.
#[derive(Debug)]
pub(crate) enum AudioSource<T: 'static> {
    System,
    Process(UserDataRef<Process<T>>),
}

impl<T: LuaTexture> FromLua for AudioSource<T> {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let table = Table::from_lua(value, lua).context("lunette: openAudio's source")?;
        if table.metatable().is_some() {
            return Err(mlua::Error::runtime(
                "lunette: openAudio's source must be a plain table without a metatable",
            ));
        }
        let kind: String = table
            .raw_get("kind")
            .context("lunette: openAudio's source kind")?;
        let known: &[&str] = match kind.as_str() {
            "system" => &["kind"],
            "process" => &["kind", "process"],
            _ => {
                return Err(mlua::Error::runtime(format!(
                    "lunette: openAudio source kind '{kind}' is not 'system' or 'process'"
                )));
            }
        };
        for pair in table.pairs::<Value, Value>() {
            let (key, _) = pair?;
            if !key.as_string().is_some_and(|name| {
                known
                    .iter()
                    .any(|field| name.as_bytes().as_ref() == field.as_bytes())
            }) {
                return Err(mlua::Error::runtime(format!(
                    "lunette: openAudio's {kind} source takes only {}",
                    known.join(", ")
                )));
            }
        }
        match kind.as_str() {
            "system" => Ok(Self::System),
            "process" => table
                .raw_get("process")
                .map(Self::Process)
                .context("lunette: openAudio's process must be a Process handle"),
            _ => unreachable!("the source kind was validated above"),
        }
    }
}

impl<T: 'static> Typed for AudioSource<T> {
    fn luau() -> Type {
        Type::Named("AudioSource")
    }
}

impl<T: 'static> Aliased for AudioSource<T> {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "A closed source descriptor. A process must belong to the current session; a queued spawn is valid.",
        name: Self::luau,
        definition: |_| {
            Type::Union(vec![
                variant("system", []),
                variant("process", [("process", Process::<NullTexture>::luau())]),
            ])
        },
    };
}

pub(crate) fn open_audio<T: LuaTexture>(
    session: &Rc<Session<T>>,
    source: AudioSource<T>,
) -> mlua::Result<AudioCapture<T>> {
    let source = match source {
        AudioSource::System => Source::System,
        AudioSource::Process(process) => {
            if !process.belongs_to(session) {
                return Err(mlua::Error::runtime(
                    "lunette: openAudio's process belongs to another session",
                ));
            }
            Source::Process(process.id())
        }
    };
    Ok(AudioCapture {
        id: session.audio().open(source),
        source,
        session: Rc::clone(session),
        closed: Cell::new(false),
    })
}

/// A read-only snapshot table with fresh process handles and shared native blocks.
#[derive(Debug)]
pub(crate) struct AudioSnapshot<T> {
    publication: Arc<CapturedSnapshot>,
    session: Rc<Session<T>>,
}

impl<T: LuaTexture> IntoLua for AudioSnapshot<T> {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        let source = lua.create_table()?;
        match self.publication.source {
            Source::System => source.set("kind", "system")?,
            Source::Process(id) => {
                source.set("kind", "process")?;
                source.set("process", Process::new(Rc::clone(&self.session), id))?;
            }
        }
        source.set_readonly(true);
        let blocks = lua.create_table_with_capacity(self.publication.blocks.len(), 0)?;
        for (index, block) in self.publication.blocks.iter().enumerate() {
            blocks.raw_set(index + 1, AudioBlock(block.clone()))?;
        }
        blocks.set_readonly(true);
        let snapshot = lua.create_table()?;
        snapshot.set("source", source)?;
        snapshot.set("state", AudioState(self.publication.state.clone()))?;
        snapshot.set("frameGeneration", self.publication.frame_generation)?;
        snapshot.set("blocks", blocks)?;
        snapshot.set_readonly(true);
        Ok(Value::Table(snapshot))
    }
}

impl<T> Typed for AudioSnapshot<T> {
    fn luau() -> Type {
        Type::Named("AudioSnapshot")
    }
}

impl<T> Aliased for AudioSnapshot<T> {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "One frame's read-only audio publication. Retained blocks remain valid in later frames.",
        name: Self::luau,
        definition: |_| {
            Type::Record(vec![
                Parameter {
                    name: "source",
                    ty: AudioSource::<NullTexture>::luau(),
                },
                Parameter {
                    name: "state",
                    ty: AudioState::luau(),
                },
                Parameter {
                    name: "frameGeneration",
                    ty: Type::NUMBER,
                },
                Parameter {
                    name: "blocks",
                    ty: AudioBlock::luau().readonly_array(),
                },
            ])
        },
    };
}

#[derive(Debug)]
pub(crate) struct AudioState(CaptureState);

impl IntoLua for AudioState {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        let table = lua.create_table()?;
        match self.0 {
            CaptureState::Starting => table.set("kind", "starting")?,
            CaptureState::Active { provenance } => {
                table.set("kind", "active")?;
                table.set(
                    "provenance",
                    provenance.map(|provenance| match provenance {
                        AttributionProvenance::PipeWireClient => "pipewire-client",
                        AttributionProvenance::ApplicationMetadata => "application-metadata",
                    }),
                )?;
            }
            CaptureState::Idle => table.set("kind", "idle")?,
            CaptureState::Unavailable { reason, detail } => {
                table.set("kind", "unavailable")?;
                table.set("reason", unavailable_reason(reason))?;
                table.set("detail", detail)?;
            }
            CaptureState::Ended => table.set("kind", "ended")?,
        }
        table.set_readonly(true);
        Ok(Value::Table(table))
    }
}

impl Typed for AudioState {
    fn luau() -> Type {
        Type::Named("AudioState")
    }
}

impl Aliased for AudioState {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "Capture status. Unavailable is recoverable and carries a reason; ended is terminal.",
        name: Self::luau,
        definition: |_| {
            Type::Union(vec![
                variant("starting", []),
                variant(
                    "active",
                    [(
                        "provenance",
                        Type::literals(&["pipewire-client", "application-metadata"]).optional(),
                    )],
                ),
                variant("idle", []),
                variant(
                    "unavailable",
                    [
                        (
                            "reason",
                            Type::literals(&[
                                "no-server",
                                "no-default-sink",
                                "invalid-default-sink",
                                "permission-denied",
                                "unsupported-format",
                                "unresolved-attribution",
                                "capacity-exceeded",
                                "graph-failure",
                            ]),
                        ),
                        ("detail", Type::STRING),
                    ],
                ),
                variant("ended", []),
            ])
        },
    };
}

/// A lightweight wrapper that shares immutable native samples without a wire identity.
#[derive(Debug)]
pub(crate) struct AudioBlock(CapturedBlock);

impl PartialEq for AudioBlock {
    fn eq(&self, other: &Self) -> bool {
        self.0.timing == other.0.timing && Arc::ptr_eq(&self.0.samples, &other.0.samples)
    }
}

impl Typed for AudioBlock {
    fn luau() -> Type {
        Type::Named("AudioBlock")
    }
}

impl UserData for AudioBlock {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        add_fields(fields);
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        add_methods(methods);
    }
}

impl Described for AudioBlock {
    const HANDLE: HandleSpec = HandleSpec {
        name: "AudioBlock",
        doc: "Immutable native interleaved stereo F32 PCM. Copy samples only when analysis needs them.",
    };
    const KIND: Option<HandleKind> = None;

    fn describe(surface: &mut impl Surface<Self>) {
        handle!(@items surface,
            field sequence(_lua, this) -> u64 { Ok(this.0.timing.sequence) }
            field generation(_lua, this) -> u64 { Ok(this.0.timing.generation.0) }
            field frameCount(_lua, this) -> usize { Ok(this.0.frames) }
            field sampleRate(_lua, _this) -> u32 { Ok(AudioFormat::STEREO_F32_48K.sample_rate()) }
            field channels(_lua, _this) -> u32 { Ok(u32::from(AudioFormat::STEREO_F32_48K.channels())) }
            /// Cumulative sample-frame position within this stream generation, not a device timestamp.
            field startFrame(_lua, this) -> u64 { Ok(this.0.timing.first_frame) }
            field timing(_lua, _this) -> SampleFrameTiming { Ok(SampleFrameTiming) }
            field gap(_lua, this) -> bool { Ok(this.0.gap_packets != 0 || this.0.gap_frames != 0) }
            field droppedFrames(_lua, this) -> u64 { Ok(this.0.gap_frames) }
            /// Returns a fresh mutable buffer with each interleaved F32 sample encoded little-endian.
            method copySamples(lua, this) -> Buffer {
                let bytes: Vec<u8> = this.0.samples.iter().flat_map(|sample| sample.to_le_bytes()).collect();
                lua.create_buffer(bytes)
            }
        );
    }
}

#[derive(Debug)]
struct SampleFrameTiming;

impl Typed for SampleFrameTiming {
    fn luau() -> Type {
        Type::Literal("sample-frames")
    }
}

impl IntoLua for SampleFrameTiming {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        "sample-frames".into_lua(lua)
    }
}

fn variant(kind: &'static str, fields: impl IntoIterator<Item = (&'static str, Type)>) -> Type {
    Type::Record(
        std::iter::once(Parameter {
            name: "kind",
            ty: Type::Literal(kind),
        })
        .chain(fields.into_iter().map(|(name, ty)| Parameter { name, ty }))
        .collect(),
    )
}

fn unavailable_reason(reason: UnavailableReason) -> &'static str {
    match reason {
        UnavailableReason::NoServer => "no-server",
        UnavailableReason::NoDefaultSink => "no-default-sink",
        UnavailableReason::InvalidDefaultSink => "invalid-default-sink",
        UnavailableReason::PermissionDenied => "permission-denied",
        UnavailableReason::UnsupportedFormat => "unsupported-format",
        UnavailableReason::UnresolvedAttribution => "unresolved-attribution",
        UnavailableReason::CapacityExceeded => "capacity-exceeded",
        UnavailableReason::GraphFailure => "graph-failure",
    }
}
