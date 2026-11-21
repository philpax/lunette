//! Publishes a native Windows window through the Lunette desktop.

#[path = "windows_input.rs"]
mod input;
#[path = "windows_processes.rs"]
mod processes;

use std::{
    rc::Rc,
    sync::Arc,
    time::{Duration, Instant},
};

use lunette_capture::{
    FrameTransform,
    audio::WindowsAudioTargets,
    windows::{self, CaptureStream, CaptureTarget, CaptureUpdate, Window},
};
use lunette_compositor::{
    config::{DEFAULT_OUTPUT, DEFAULT_SEAT},
    protocol::{
        Command, ContentType, ModifierState, OutputMode, OutputScale, OutputSnapshot, PixelBuffer,
        PixelSize, RefreshRate, SeatId, SeatSnapshot, SinkId, Snapshot, SourceCrop, SurfaceId,
        ToplevelStates, WindowId, WindowSnapshot,
    },
};
use lunette_lovr::raw::{lovrGraphicsIsInitialized, lovrGraphicsWait};
use tracing::{info, warn};

use crate::{
    events::LuaEvent,
    layers::{BlitLedger, LovrBlits, LovrLayers, submit_window_layers},
    lua::{PoolRegistry, Session, monitor_input::WindowsCommand},
    mirrors::{MirrorRegistry, WindowsMirrors},
    texture::{Alpha, LovrTexture, TextureDescription, TextureLedger},
};

const NO_PIXELS: PixelSize = PixelSize::new(0, 0);

#[derive(Debug, Default)]
pub struct Startup {
    pub window: Option<Window>,
    pub mirrors: Rc<WindowsMirrors>,
    pub audio_targets: WindowsAudioTargets,
}

#[derive(Debug)]
pub struct FrameDriver {
    session: Rc<Session<LovrTexture>>,
    layers: Rc<PoolRegistry<LovrLayers>>,
    mirrors: Rc<WindowsMirrors>,
    blits: LovrBlits,
    blitted: BlitLedger,
    captures: Vec<WindowCapture>,
    programs: processes::WindowsPrograms,
    next_caption_scan: Instant,
    next_id: u64,
    snapshot: Arc<Snapshot>,
    input: input::DesktopInput,
}

#[derive(Debug)]
struct WindowCapture {
    window: windows::WindowId,
    stream: CaptureStream,
    snapshot: WindowSnapshot,
    // A static window might not repaint after a graphics restart.
    pixels: Option<PixelBuffer>,
    needs_upload: bool,
}

#[derive(Clone, Copy)]
enum Change {
    Opened,
    Resized,
    Closed,
    Unchanged,
}

impl WindowCapture {
    fn update(&mut self, session: &Session<LovrTexture>, graphics_ready: bool) -> Change {
        match self.stream.latest() {
            Some(CaptureUpdate::Frame(pixels)) => {
                self.pixels = Some(pixels);
                self.needs_upload = true;
            }
            Some(CaptureUpdate::Closed) => return Change::Closed,
            Some(CaptureUpdate::Failed(error)) => {
                warn!(title = ?self.snapshot.title, %error, "Windows window capture ended");
                return Change::Closed;
            }
            None => {}
        }
        let Some(pixels) = self
            .pixels
            .as_ref()
            .filter(|_| graphics_ready && self.needs_upload)
        else {
            return Change::Unchanged;
        };
        self.needs_upload = false;
        let description = TextureDescription {
            size: pixels.size(),
            alpha: Alpha::Opaque,
        };
        if !install_pixels(session, self.snapshot.surface, pixels, description) {
            return Change::Unchanged;
        }
        // Publish the dimensions with the upload that supplies them.
        let previous = std::mem::replace(&mut self.snapshot.size, description.size);
        if previous == NO_PIXELS {
            info!(title = ?self.snapshot.title, width = description.size.width, height = description.size.height, "captured Windows window");
            Change::Opened
        } else if previous != description.size {
            Change::Resized
        } else {
            Change::Unchanged
        }
    }
}

impl FrameDriver {
    pub fn new(
        session: Rc<Session<LovrTexture>>,
        layers: Rc<PoolRegistry<LovrLayers>>,
        blits: LovrBlits,
        startup: Startup,
    ) -> Self {
        if let Some(window) = startup.window {
            session.window_picker.borrow_mut().queue(window);
        }
        Self {
            session,
            layers,
            mirrors: startup.mirrors,
            blits,
            blitted: BlitLedger::new(),
            captures: Vec::new(),
            programs: processes::WindowsPrograms::new(startup.audio_targets),
            next_caption_scan: Instant::now(),
            next_id: 0,
            snapshot: Arc::new(Snapshot {
                seats: vec![SeatSnapshot {
                    seat: DEFAULT_SEAT,
                    name: "lunette".into(),
                    modifiers: ModifierState::default(),
                    clipboard_bridge: false,
                    drag: None,
                }],
                outputs: vec![OutputSnapshot {
                    output: DEFAULT_OUTPUT,
                    mode: OutputMode {
                        size: PixelSize {
                            width: 1920,
                            height: 1080,
                        },
                        scale: OutputScale::ONE,
                        refresh: RefreshRate::from_millihertz(60_000),
                    },
                }],
                ..Snapshot::default()
            }),
            input: input::DesktopInput::default(),
        }
    }

    pub fn begin_frame(&mut self) {
        let graphics_ready = graphics_ready();
        self.programs.poll();
        let selections = self.session.window_picker.borrow_mut().drain();
        for window in selections {
            if let Err(error) = self.start_capture(&window) {
                self.session.window_picker.borrow_mut().ended(window.id);
                warn!(title = %window.title, %error, "Windows window capture could not start");
            }
        }
        let events = self.update_captures(graphics_ready);
        if let Some(processes) = self.programs.take_snapshot() {
            let snapshot = Arc::make_mut(&mut self.snapshot);
            snapshot.generation = snapshot.generation.next();
            snapshot.processes = processes;
        }
        let monitors = self.mirrors.poll();
        self.update_monitors(graphics_ready);
        self.session.begin(Arc::clone(&self.snapshot));
        for event in self.programs.take_events() {
            self.session.audio().event(&event);
            if let Some(event) = LuaEvent::from_compositor(&event) {
                self.session.push_event(event);
            }
        }
        for event in events {
            self.session.push_event(event);
        }
        for monitor in monitors {
            self.session.push_event(LuaEvent::MonitorAdded { monitor });
        }
        self.session.audio().begin_frame(&self.snapshot);

        if graphics_ready {
            self.session.resolve_layers();
            self.session.with_textures(TextureLedger::refresh_stable);
            submit_window_layers(
                &self.session,
                &self.layers,
                &mut self.blits,
                &mut self.blitted,
            );
        }
    }

    fn update_monitors(&self, graphics_ready: bool) {
        let frames = if graphics_ready {
            self.mirrors.take_frames()
        } else {
            Vec::new()
        };
        self.session.with_monitor_textures(|textures| {
            for monitor in self.mirrors.take_retired() {
                if let Some(texture) = textures.forget(&monitor) {
                    texture.release_ref();
                }
            }
            for (monitor, pixels) in frames {
                let description = TextureDescription {
                    size: pixels.size(),
                    alpha: Alpha::Opaque,
                };
                // SAFETY: the calling frame owns an initialized graphics device.
                if textures.describe(&monitor) == Some(description)
                    && textures
                        .texture(&monitor)
                        .is_some_and(|texture| unsafe { texture.refill(&pixels, description) })
                {
                    self.mirrors.uploaded(&monitor, pixels);
                    continue;
                }
                // SAFETY: same frame and graphics device as the refill.
                match unsafe { LovrTexture::upload(&pixels) } {
                    Ok(texture) => {
                        self.mirrors.uploaded(&monitor, pixels);
                        if let Some(previous) = textures.install(
                            monitor,
                            None,
                            texture,
                            description,
                            FrameTransform::Normal,
                        ) {
                            previous.release_ref();
                        }
                    }
                    Err(error) => {
                        warn!(%monitor, %error, "Windows monitor pixels could not be uploaded")
                    }
                }
            }
        });
    }

    fn start_capture(&mut self, source: &Window) -> std::io::Result<()> {
        let id = self
            .next_id
            .checked_add(1)
            .filter(|id| *id < (1 << 53))
            .ok_or_else(|| std::io::Error::other("window identifiers exhausted"))?;
        let (Some(window), Some(surface), Some(sink)) =
            (WindowId::new(id), SurfaceId::new(id), SinkId::new(id))
        else {
            return Err(std::io::Error::other("invalid window identifiers"));
        };
        let stream = CaptureStream::start(CaptureTarget::Window(source.id))?;
        let process = self.programs.adopt(source.id);
        self.next_id = id;
        self.captures.push(WindowCapture {
            window: source.id,
            stream,
            pixels: None,
            needs_upload: false,
            snapshot: WindowSnapshot {
                window,
                surface,
                sink,
                process,
                output: DEFAULT_OUTPUT,
                title: Some(source.title.clone()),
                app_id: windows::app_id(source.id),
                size: NO_PIXELS,
                min_size: None,
                max_size: None,
                parent: None,
                states: ToplevelStates::new(),
                content_type: ContentType::None,
                source_crop: SourceCrop::FULL,
                server_side_decorations: false,
                children: Vec::new(),
            },
        });
        Ok(())
    }

    fn update_captures(&mut self, graphics_ready: bool) -> Vec<LuaEvent> {
        let mut events = Vec::new();
        let mut changed = false;
        let now = Instant::now();
        let scan_captions = now >= self.next_caption_scan;
        if scan_captions {
            self.next_caption_scan = now + Duration::from_millis(250);
        }
        self.captures.retain_mut(|capture| {
            let stopping = self.session.window_picker.borrow().stopping(capture.window);
            let change = if stopping {
                Change::Closed
            } else {
                capture.update(&self.session, graphics_ready)
            };
            let snapshot = &mut capture.snapshot;
            if scan_captions
                && let Some(title) = windows::window_title(capture.window)
                && snapshot.title != title
            {
                snapshot.title = title;
                changed = true;
            }
            match change {
                Change::Opened => {
                    changed = true;
                    events.push(LuaEvent::WindowOpened {
                        window: snapshot.window,
                    });
                }
                Change::Resized => {
                    changed = true;
                    self.input.window_changed(snapshot.sink, false);
                }
                Change::Closed => {
                    self.session
                        .window_picker
                        .borrow_mut()
                        .ended(capture.window);
                    if snapshot.size != NO_PIXELS {
                        self.input.window_changed(snapshot.sink, true);
                        for texture in self
                            .session
                            .with_textures(|ledger| ledger.forget(snapshot.surface))
                        {
                            texture.release_ref();
                        }
                        changed = true;
                        events.push(LuaEvent::WindowClosed {
                            window: snapshot.window,
                        });
                    }
                    return false;
                }
                Change::Unchanged => {}
            }
            true
        });
        if changed {
            let snapshot = Arc::make_mut(&mut self.snapshot);
            snapshot.generation = snapshot.generation.next();
            snapshot.windows = self
                .captures
                .iter()
                .filter(|capture| capture.snapshot.size != NO_PIXELS)
                .map(|capture| capture.snapshot.clone())
                .collect();
        }
        events
    }

    pub fn end_frame(&mut self) {
        let target = |sink| {
            self.captures
                .iter()
                .find(|capture| capture.snapshot.sink == sink && capture.snapshot.size != NO_PIXELS)
                .map(|capture| (capture.window, capture.snapshot.size))
        };
        self.input.check_focus(target, &self.mirrors);
        for command in self.session.flush_windows() {
            let command = match command {
                WindowsCommand::Native(command) => command,
                WindowsCommand::Monitor {
                    seat,
                    monitor,
                    input,
                } => {
                    if known_seat(&self.snapshot, seat) {
                        self.input
                            .apply_monitor(seat, monitor, input, &self.mirrors);
                    }
                    continue;
                }
            };
            match command {
                Command::CreateSeat { seat, name, .. } if !known_seat(&self.snapshot, seat) => {
                    let snapshot = Arc::make_mut(&mut self.snapshot);
                    snapshot.seats.push(SeatSnapshot {
                        seat,
                        name,
                        modifiers: ModifierState::default(),
                        clipboard_bridge: false,
                        drag: None,
                    });
                    snapshot.generation = snapshot.generation.next();
                }
                Command::DestroySeat { seat }
                    if seat != DEFAULT_SEAT && known_seat(&self.snapshot, seat) =>
                {
                    self.input.remove_seat(seat);
                    let snapshot = Arc::make_mut(&mut self.snapshot);
                    snapshot.seats.retain(|entry| entry.seat != seat);
                    snapshot.generation = snapshot.generation.next();
                }
                Command::ResetSeat { seat, .. } => self.input.remove_seat(seat),
                Command::Spawn(request) => self.programs.spawn(request),
                Command::CloseWindow { window } => {
                    if let Some(capture) = self
                        .captures
                        .iter()
                        .find(|capture| capture.snapshot.window == window)
                        && let Err(error) = windows::close(capture.window)
                    {
                        warn!(%error, "Windows window could not be closed");
                    }
                }
                Command::ConfigureWindow {
                    window,
                    size: Some(size),
                    ..
                } => {
                    if let Some(capture) = self
                        .captures
                        .iter()
                        .find(|capture| capture.snapshot.window == window)
                        && let Err(error) = windows::resize_window(capture.window, size)
                    {
                        warn!(%error, "Windows window could not be resized");
                    }
                }
                other => self
                    .input
                    .apply(other, target, |seat| known_seat(&self.snapshot, seat)),
            }
        }
    }

    pub fn quiesce(&mut self) {
        self.input.reset();
        // SAFETY: the frame thread owns LÖVR and no pass is open.
        if graphics_ready() && !unsafe { lovrGraphicsWait() } {
            warn!("the graphics device did not drain before shutdown");
        }
        self.session.claims().shutdown();
        self.layers.forget_claims();
        self.blitted = BlitLedger::new();
        for texture in self.session.with_textures(TextureLedger::take_all) {
            texture.release_ref();
        }
        for texture in self
            .session
            .with_monitor_textures(|textures| textures.take_all())
        {
            texture.release_ref();
        }
        self.mirrors.clear_uploads();
        for capture in &mut self.captures {
            capture.needs_upload = capture.pixels.is_some();
        }
    }

    pub fn shutdown(&mut self) {
        self.quiesce();
        self.mirrors.shutdown();
        for capture in self.captures.drain(..) {
            if capture.stream.stop().is_err() {
                warn!("the Windows capture worker stopped unexpectedly");
            }
        }
    }
}

fn known_seat(snapshot: &Snapshot, seat: SeatId) -> bool {
    snapshot.seats.iter().any(|entry| entry.seat == seat)
}

fn install_pixels(
    session: &Session<LovrTexture>,
    surface: SurfaceId,
    pixels: &PixelBuffer,
    description: TextureDescription,
) -> bool {
    session.with_textures(|ledger| {
        // SAFETY: the calling frame owns an initialized graphics device.
        if ledger.update_pixels(surface, description, |texture| unsafe {
            texture.refill(pixels, description)
        }) {
            return true;
        }
        // SAFETY: same device and thread as the refill.
        match unsafe { LovrTexture::upload(pixels) } {
            Ok(texture) => {
                for previous in ledger.install(surface, texture, description) {
                    previous.release_ref();
                }
                true
            }
            Err(error) => {
                warn!(%error, "Windows window pixels could not be uploaded");
                false
            }
        }
    })
}

fn graphics_ready() -> bool {
    // SAFETY: the process's frame thread queries its own graphics module.
    unsafe { lovrGraphicsIsInitialized() }
}
