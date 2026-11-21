use std::{
    thread,
    time::{Duration, Instant},
};

use ::windows::{
    Win32::{
        Foundation::{COLORREF, HWND, LPARAM, LRESULT, WPARAM},
        Graphics::Gdi::{
            BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, PAINTSTRUCT,
            UpdateWindow,
        },
        System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::{
            CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, MSG, PM_REMOVE,
            PeekMessageW, RegisterClassW, SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOMOVE,
            SWP_NOZORDER, SetWindowPos, ShowWindow, TranslateMessage, WM_PAINT, WNDCLASSW,
            WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP,
        },
    },
    core::w,
};

use lunette_compositor::protocol::{PixelBuffer, PixelSize};

use crate::windows::{
    CaptureStream, CaptureTarget, CaptureUpdate, WindowId, close, desktop::DpiContext, monitors,
    type_text,
};

struct Fixture(HWND);

impl Drop for Fixture {
    fn drop(&mut self) {
        if !self.0.0.is_null() {
            // SAFETY: the fixture owns this HWND on the test thread.
            let _ = unsafe { DestroyWindow(self.0) };
        }
    }
}

fn poll_until<T>(mut read: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut message = MSG::default();
    loop {
        // SAFETY: the messages belong to this thread and are dispatched before polling capture.
        unsafe {
            while PeekMessageW(&raw mut message, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&raw const message);
                DispatchMessageW(&raw const message);
            }
        }
        if let Some(value) = read() {
            return value;
        }
        assert!(Instant::now() < deadline, "Windows capture did not respond");
        thread::sleep(Duration::from_millis(15));
    }
}

fn frame_with_size(capture: &CaptureStream, width: u32, height: u32) -> PixelBuffer {
    let mut last_sample = None;
    poll_until(|| {
        let frame = match capture.latest()? {
            CaptureUpdate::Frame(frame) => frame,
            update => panic!("capture ended before producing a frame: {update:?}"),
        };
        let size = frame.size();
        let center = ((size.height / 2 * size.width + size.width / 2) * 4) as usize;
        let color = &frame.pixels()[center..center + 3];
        let sample = (size, [color[0], color[1], color[2]]);
        if last_sample.replace(sample) != Some(sample) {
            eprintln!(
                "capture frame {size:?}, center BGRA {:?}",
                &frame.pixels()[center..center + 4]
            );
        }
        (size == PixelSize::new(width, height) && color == [0x22, 0x33, 0x88]).then_some(frame)
    })
}

unsafe extern "system" fn paint(
    handle: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_PAINT {
        let mut painting = PAINTSTRUCT::default();
        // SAFETY: this is a WM_PAINT callback, so the window and paint DC belong to this thread.
        unsafe {
            let dc = BeginPaint(handle, &raw mut painting);
            let brush = CreateSolidBrush(COLORREF(0x0022_3388));
            FillRect(dc, &raw const painting.rcPaint, brush);
            let _ = DeleteObject(brush.into());
            let _ = EndPaint(handle, &raw const painting);
        }
        LRESULT(0)
    } else {
        // SAFETY: forwards the original arguments to the standard window procedure.
        unsafe { DefWindowProcW(handle, message, wparam, lparam) }
    }
}

#[test]
#[ignore = "requires an interactive Windows desktop with Windows Graphics Capture"]
#[expect(clippy::expect_used, reason = "a failed native fixture prerequisite fails this test")]
fn captures_resizes_and_closes_a_native_window() {
    let _dpi = DpiContext::enter();
    assert!(!monitors().expect("monitor enumeration succeeds").is_empty());
    let class = w!("LunetteWindowsCaptureFixture");
    // SAFETY: asks for the handle of the current executable and registers its window procedure.
    let instance = unsafe { GetModuleHandleW(None) }
        .expect("test module is loaded")
        .into();
    let definition = WNDCLASSW {
        hInstance: instance,
        lpszClassName: class,
        lpfnWndProc: Some(paint),
        ..WNDCLASSW::default()
    };
    assert_ne!(unsafe { RegisterClassW(&raw const definition) }, 0);
    // SAFETY: uses the registered class and owns the returned HWND on this thread.
    let mut fixture = Fixture(
        unsafe {
            CreateWindowExW(
                WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                class,
                w!("Lunette Windows capture test"),
                WS_POPUP,
                48,
                48,
                173,
                111,
                None,
                None,
                Some(instance),
                None,
            )
        }
        .expect("test window opens"),
    );
    // SAFETY: show the fixture without taking focus and paint it on its owning thread.
    unsafe {
        let _ = ShowWindow(fixture.0, SW_SHOWNOACTIVATE);
        let _ = UpdateWindow(fixture.0);
    }
    let target = WindowId::from_handle(fixture.0).expect("test window has a live identity");
    let capture =
        CaptureStream::start(CaptureTarget::Window(target)).expect("window capture starts");
    let frame = frame_with_size(&capture, 173, 111);
    assert_eq!(frame.pixels().len(), 173 * 111 * 4);
    // SAFETY: the fixture owns this live window, and the call keeps its position and activation.
    unsafe {
        SetWindowPos(
            fixture.0,
            None,
            0,
            0,
            191,
            125,
            SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOZORDER,
        )
        .expect("test window resizes");
    }
    let resized = frame_with_size(&capture, 191, 125);
    assert_eq!(resized.pixels().len(), 191 * 125 * 4);
    assert!(!type_text(target, "unfocused").expect("unfocused input is refused"));
    assert!(close(target).expect("close request reaches the test window"));
    poll_until(|| match capture.latest()? {
        CaptureUpdate::Closed => Some(()),
        CaptureUpdate::Failed(error) => panic!("capture failed while closing: {error}"),
        CaptureUpdate::Frame(_) => None,
    });
    fixture.0 = HWND::default();
    assert!(!close(target).expect("a closed window is no longer a target"));
    assert!(capture.latest().is_none());
}
