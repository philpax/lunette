//! The desktop's list of native windows available for explicit capture.

use crate::lua::{Session, declarations::record};

record! {
    /// A native window that the host can capture.
    struct CaptureWindow {
        /// Session-local identity, valid while this window is available.
        id: u64,
        title: String,
        /// A capture is running or has been requested.
        captured: bool,
    }
}

pub(crate) fn choices<T>(session: &Session<T>) -> mlua::Result<Option<Vec<CaptureWindow>>> {
    #[cfg(windows)]
    return session
        .window_picker
        .borrow_mut()
        .refresh()
        .map(Some)
        .map_err(mlua::Error::external);
    #[cfg(not(windows))]
    {
        let _ = session;
        Ok(None)
    }
}

pub(crate) fn capture<T>(session: &Session<T>, id: u64) -> bool {
    #[cfg(windows)]
    return session.window_picker.borrow_mut().select(id);
    #[cfg(not(windows))]
    {
        let _ = (session, id);
        false
    }
}

pub(crate) fn stop<T>(session: &Session<T>, id: u64) -> bool {
    #[cfg(windows)]
    return session.window_picker.borrow_mut().stop(id);
    #[cfg(not(windows))]
    {
        let _ = (session, id);
        false
    }
}

#[cfg(windows)]
mod windows_picker {
    use std::{
        collections::{HashMap, HashSet},
        io, mem,
    };

    use lunette_capture::windows::{self, Window, WindowId};

    use super::CaptureWindow;

    #[derive(Debug, Default)]
    pub(crate) struct WindowPicker {
        next: u64,
        choices: HashMap<WindowId, u64>,
        selected: HashMap<WindowId, String>,
        pending: Vec<Window>,
        stopping: HashSet<WindowId>,
    }

    impl WindowPicker {
        pub(super) fn refresh(&mut self) -> io::Result<Vec<CaptureWindow>> {
            let mut windows: HashMap<_, _> = windows::windows()
                .map_err(io::Error::other)?
                .into_iter()
                .map(|window| (window.id, window.title))
                .collect();
            for (&window, title) in &self.selected {
                windows.entry(window).or_insert_with(|| title.clone());
            }
            let mut choices = HashMap::with_capacity(windows.len());
            let mut entries = Vec::with_capacity(windows.len());
            for (window, title) in windows {
                let id = match self.choices.get(&window) {
                    Some(&id) => id,
                    None => {
                        self.next = self
                            .next
                            .checked_add(1)
                            .filter(|id| *id < (1 << 53))
                            .ok_or_else(|| {
                                io::Error::other("window selection identifiers exhausted")
                            })?;
                        self.next
                    }
                };
                choices.insert(window, id);
                entries.push(CaptureWindow {
                    id,
                    title,
                    captured: self.selected.contains_key(&window)
                        && !self.stopping.contains(&window),
                });
            }
            self.choices = choices;
            entries.sort_by(|a, b| a.title.cmp(&b.title).then(a.id.cmp(&b.id)));
            Ok(entries)
        }

        fn resolve(&self, id: u64) -> Option<WindowId> {
            self.choices
                .iter()
                .find_map(|(&window, &choice)| (choice == id).then_some(window))
        }

        pub(super) fn select(&mut self, id: u64) -> bool {
            let Some(window) = self.resolve(id).and_then(windows::window) else {
                return false;
            };
            self.queue(window)
        }

        pub(super) fn stop(&mut self, id: u64) -> bool {
            let Some(window) = self
                .resolve(id)
                .filter(|key| self.selected.contains_key(key))
            else {
                return false;
            };
            if let Some(index) = self.pending.iter().position(|pending| pending.id == window) {
                self.pending.swap_remove(index);
                self.ended(window);
                return true;
            }
            self.stopping.insert(window)
        }

        pub(crate) fn queue(&mut self, window: Window) -> bool {
            if self.selected.contains_key(&window.id) {
                return false;
            }
            self.selected.insert(window.id, window.title.clone());
            self.pending.push(window);
            true
        }

        pub(crate) fn drain(&mut self) -> Vec<Window> {
            mem::take(&mut self.pending)
        }

        pub(crate) fn ended(&mut self, window: WindowId) {
            self.selected.remove(&window);
            self.stopping.remove(&window);
        }

        pub(crate) fn stopping(&self, window: WindowId) -> bool {
            self.stopping.contains(&window)
        }
    }
}

#[cfg(windows)]
pub(crate) use windows_picker::WindowPicker;
