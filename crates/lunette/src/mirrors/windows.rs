//! Tracks Windows displays and owns explicitly requested capture workers.

use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    io, mem,
    time::{Duration, Instant},
};

use lunette_capture::{
    mirror::{MirrorOutcome, SelectionOutcome, SelectionState},
    monitor::{LogicalGeometry, LogicalPosition, LogicalSize, MonitorKey, PixelExtent},
    windows::{self, CaptureStream, CaptureTarget, CaptureUpdate, Monitor, MonitorId},
};
use lunette_compositor::protocol::PixelBuffer;
use tracing::warn;

use super::{MirrorRegistry, MonitorState};

#[derive(Debug, Default)]
pub struct WindowsMirrors {
    state: RefCell<Registry>,
}

#[derive(Debug, Default)]
struct Registry {
    displays: HashMap<MonitorKey, Monitor>,
    shares: HashMap<MonitorKey, Share>,
    retired: HashSet<MonitorKey>,
    next_scan: Option<Instant>,
}

#[derive(Debug)]
struct Share {
    stream: Option<CaptureStream>,
    showing: bool,
    input_ready: bool,
    // A static or paused display might not repaint after a graphics restart.
    pixels: Option<PixelBuffer>,
}

impl WindowsMirrors {
    #[must_use]
    pub fn new() -> Self {
        let registry = Self::default();
        registry.poll();
        registry
    }

    pub(crate) fn take_frames(&self) -> Vec<(MonitorKey, PixelBuffer)> {
        let mut registry = self.state.borrow_mut();
        let mut frames = Vec::new();
        let mut ended = Vec::new();
        for (key, share) in &mut registry.shares {
            match share.stream.as_ref().and_then(CaptureStream::latest) {
                Some(CaptureUpdate::Frame(pixels)) => {
                    share.input_ready = true;
                    frames.push((key.clone(), pixels));
                }
                Some(CaptureUpdate::Closed) => ended.push(key.clone()),
                Some(CaptureUpdate::Failed(error)) => {
                    warn!(monitor = %key, %error, "Windows monitor capture ended");
                    ended.push(key.clone());
                }
                None => {
                    if !share.showing
                        && let Some(pixels) = share.pixels.take()
                    {
                        frames.push((key.clone(), pixels));
                    }
                }
            }
        }
        for key in ended {
            registry.dismiss(&key);
        }
        frames
    }

    pub(crate) fn uploaded(&self, key: &MonitorKey, pixels: PixelBuffer) {
        if let Some(share) = self.state.borrow_mut().shares.get_mut(key) {
            share.showing = true;
            share.pixels = Some(pixels);
        }
    }

    pub(crate) fn take_retired(&self) -> HashSet<MonitorKey> {
        mem::take(&mut self.state.borrow_mut().retired)
    }

    pub(crate) fn input_target(&self, monitor: &MonitorKey) -> Option<MonitorId> {
        let registry = self.state.borrow();
        let share = registry.shares.get(monitor)?;
        if !share.showing || !share.input_ready || share.stream.is_none() {
            return None;
        }
        registry
            .displays
            .get(monitor)
            .map(|display| display.id.clone())
    }

    pub(crate) fn clear_uploads(&self) {
        for share in self.state.borrow_mut().shares.values_mut() {
            share.showing = false;
        }
    }

    pub(crate) fn shutdown(&self) {
        let shares = mem::take(&mut self.state.borrow_mut().shares);
        for (_, share) in shares {
            if let Some(stream) = share.stream
                && stream.stop().is_err()
            {
                warn!("a Windows monitor capture worker stopped unexpectedly");
            }
        }
    }
}

impl Registry {
    fn describe(&self, key: &MonitorKey, display: &Monitor) -> MonitorState {
        let bounds = display.bounds;
        let share = self.shares.get(key);
        let name = display.id.device();
        let name = name
            .strip_prefix(r"\\.\DISPLAY")
            .map_or_else(|| name.to_owned(), |number| format!("Display {number}"));
        MonitorState {
            key: key.clone(),
            name,
            geometry: LogicalGeometry::new(
                LogicalPosition::new(bounds.x, bounds.y),
                LogicalSize::new(bounds.width, bounds.height),
            ),
            pixels: PixelExtent::new(bounds.width, bounds.height),
            mirrored: share.is_some_and(|active| active.showing || active.stream.is_none()),
            pending: share.is_some_and(|active| !active.showing && active.stream.is_some()),
        }
    }

    fn dismiss(&mut self, key: &MonitorKey) -> bool {
        if self.shares.remove(key).is_none() {
            return false;
        }
        self.retired.insert(key.clone());
        true
    }
}

fn start(display: &Monitor) -> io::Result<CaptureStream> {
    CaptureStream::start(CaptureTarget::Monitor(display.id.clone()))
}

impl MirrorRegistry for WindowsMirrors {
    fn poll(&self) -> Vec<MonitorKey> {
        let mut registry = self.state.borrow_mut();
        let now = Instant::now();
        if registry.next_scan.is_some_and(|due| now < due) {
            return Vec::new();
        }
        registry.next_scan = Some(now + Duration::from_secs(1));
        let displays = match windows::monitors() {
            Ok(displays) => displays,
            Err(error) => {
                warn!(%error, "Windows display enumeration failed");
                return Vec::new();
            }
        };
        let displays: HashMap<_, _> = displays
            .into_iter()
            .map(|display| {
                let identity = display
                    .id
                    .interface()
                    .unwrap_or_else(|| display.id.device().into());
                (MonitorKey::WindowsDisplay(identity.to_lowercase()), display)
            })
            .collect();
        let removed: Vec<_> = registry
            .displays
            .iter()
            .filter(|(key, old)| displays.get(*key).is_none_or(|new| new.id != old.id))
            .map(|(key, _)| key.clone())
            .collect();
        for key in removed {
            registry.displays.remove(&key);
            registry.dismiss(&key);
        }
        let added = displays
            .keys()
            .filter(|key| !registry.displays.contains_key(*key))
            .cloned()
            .collect();
        registry.displays = displays;
        added
    }

    fn monitors(&self) -> Vec<MonitorState> {
        let registry = self.state.borrow();
        let mut monitors: Vec<_> = registry
            .displays
            .iter()
            .map(|(key, display)| registry.describe(key, display))
            .collect();
        monitors.sort_by(|a, b| a.name.cmp(&b.name));
        monitors
    }

    fn state(&self, monitor: &MonitorKey) -> Option<MonitorState> {
        let registry = self.state.borrow();
        registry
            .displays
            .get(monitor)
            .map(|display| registry.describe(monitor, display))
    }

    fn mirror(&self, monitor: &MonitorKey) -> MirrorOutcome {
        let mut registry = self.state.borrow_mut();
        if registry.shares.contains_key(monitor) {
            return MirrorOutcome::AlreadyMirroring;
        }
        let Some(display) = registry.displays.get(monitor) else {
            return MirrorOutcome::NoSuchMonitor;
        };
        match start(display) {
            Ok(stream) => {
                registry.shares.insert(
                    monitor.clone(),
                    Share {
                        stream: Some(stream),
                        showing: false,
                        input_ready: false,
                        pixels: None,
                    },
                );
                MirrorOutcome::Requested
            }
            Err(error) => MirrorOutcome::Failed(error.to_string()),
        }
    }

    fn dismiss(&self, monitor: &MonitorKey) -> bool {
        self.state.borrow_mut().dismiss(monitor)
    }

    fn set_paused(&self, monitor: &MonitorKey, paused: bool) -> bool {
        let mut registry = self.state.borrow_mut();
        let Registry {
            displays, shares, ..
        } = &mut *registry;
        let Some(share) = shares.get_mut(monitor) else {
            return false;
        };
        if paused {
            share.stream = None;
            share.input_ready = false;
        } else if share.stream.is_none() {
            let Some(display) = displays.get(monitor) else {
                return false;
            };
            match start(display) {
                Ok(stream) => share.stream = Some(stream),
                Err(error) => {
                    warn!(monitor = %monitor, %error, "Windows monitor capture could not resume");
                    return false;
                }
            }
        }
        true
    }

    fn select_monitors(&self) -> SelectionOutcome {
        if self.state.borrow().displays.is_empty() {
            SelectionOutcome::NoMonitors
        } else {
            SelectionOutcome::ChooseIndividually
        }
    }

    fn selection_state(&self) -> SelectionState {
        SelectionState::Idle
    }

    fn is_direct(&self, monitor: &MonitorKey) -> bool {
        self.state.borrow().displays.contains_key(monitor)
    }

    fn requires_explicit_share(&self) -> bool {
        true
    }
}
