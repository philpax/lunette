//! Windows-only: reads explicitly selected Windows Graphics Capture frames back to CPU memory.

use std::{
    marker::PhantomData,
    ptr::{self, NonNull},
    rc::Rc,
    slice,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use ::windows::{
    Foundation::TypedEventHandler,
    Graphics::{
        Capture::{
            Direct3D11CaptureFrame, Direct3D11CaptureFramePool, GraphicsCaptureItem,
            GraphicsCaptureSession,
        },
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
        SizeInt32,
    },
    Win32::{
        Foundation::{E_FAIL, E_INVALIDARG, E_NOTIMPL, HMODULE},
        Graphics::{
            Direct3D::D3D_DRIVER_TYPE_HARDWARE,
            Direct3D11::{
                D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAP_READ,
                D3D11_MAPPED_SUBRESOURCE, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
                D3D11_USAGE_STAGING, D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext,
                ID3D11Multithread, ID3D11Texture2D,
            },
            Dxgi::IDXGIDevice,
        },
        System::WinRT::{
            Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess},
            Graphics::Capture::IGraphicsCaptureItemInterop,
            RO_INIT_MULTITHREADED, RoInitialize, RoUninitialize,
        },
    },
    core::{Error, Interface, Result, factory},
};
use lunette_compositor::protocol::{PixelBuffer, PixelFormat, PixelSize};
use tracing::debug;

use crate::windows::desktop::{MonitorId, WindowId};

const PIXEL_FORMAT: DirectXPixelFormat = DirectXPixelFormat::B8G8R8A8UIntNormalized;
const POOL_FRAMES: i32 = 2;
const BYTES_PER_PIXEL: usize = PixelFormat::BYTES_PER_PIXEL as usize;

/// A target selected from the Windows desktop roster.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CaptureTarget {
    Window(WindowId),
    Monitor(MonitorId),
}

impl CaptureTarget {
    fn is_present(&self) -> bool {
        match self {
            Self::Window(window) => window.live_handle().is_some(),
            Self::Monitor(monitor) => monitor.live_handle().is_some(),
        }
    }
}

/// An active capture. Poll on a capture worker, since CPU readback can wait for the GPU.
pub struct Capture {
    session: GraphicsCaptureSession,
    pool: Direct3D11CaptureFramePool,
    item: GraphicsCaptureItem,
    target: CaptureTarget,
    closed_token: i64,
    closed: Arc<AtomicBool>,
    staging: Option<ID3D11Texture2D>,
    context: ID3D11DeviceContext,
    native_device: ID3D11Device,
    device: IDirect3DDevice,
    size: SizeInt32,
    _apartment: Apartment,
}

impl Capture {
    /// Starts capturing a selected window or display. Windows owns the capture indicator.
    ///
    /// # Errors
    ///
    /// Returns an error when capture is unavailable, the target disappears, or setup fails.
    pub fn open(target: &CaptureTarget) -> Result<Self> {
        let apartment = Apartment::start()?;
        if !GraphicsCaptureSession::IsSupported()? {
            return Err(Error::new(
                E_NOTIMPL,
                "Windows Graphics Capture is unavailable",
            ));
        }
        let interop = factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
        let item: GraphicsCaptureItem = match target {
            CaptureTarget::Window(window) => {
                let handle = window.live_handle().ok_or_else(target_gone)?;
                // SAFETY: the HWND was just checked and the return interface is GraphicsCaptureItem.
                unsafe { interop.CreateForWindow(handle)? }
            }
            CaptureTarget::Monitor(monitor) => {
                let handle = monitor.live_handle().ok_or_else(target_gone)?;
                // SAFETY: the HMONITOR was just checked and the return interface is GraphicsCaptureItem.
                unsafe { interop.CreateForMonitor(handle)? }
            }
        };

        let (native_device, context) = d3d_device()?;
        let threading: ID3D11Multithread = context.cast()?;
        // SAFETY: the immediate context is live. The free-threaded frame pool can use it while
        // the capture worker reads back a frame, so D3D must serialize those calls.
        let _ = unsafe { threading.SetMultithreadProtected(true) };
        let dxgi: IDXGIDevice = native_device.cast()?;
        // SAFETY: dxgi is a live device with BGRA support.
        let device: IDirect3DDevice =
            unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi)? }.cast()?;
        let closed = Arc::new(AtomicBool::new(false));
        let closed_handler = Arc::clone(&closed);
        let closed_token = item.Closed(&TypedEventHandler::new(move |_, _| {
            closed_handler.store(true, Ordering::Release);
            Ok(())
        }))?;
        let size = item.Size()?;
        frame_dimensions(size)?;
        let (pool, session) = start_capture(&device, &item, size)?;
        Ok(Self {
            session,
            pool,
            item,
            target: target.clone(),
            closed_token,
            closed,
            staging: None,
            context,
            native_device,
            device,
            size,
            _apartment: apartment,
        })
    }

    /// Reports whether Windows has closed the selected capture target.
    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire) || !self.target.is_present()
    }

    /// Polls the latest pending frame as tightly packed BGRA8 pixels, top row first.
    /// A resize drops the old pool's frame.
    ///
    /// # Errors
    ///
    /// Returns an error if frame acquisition or readback fails.
    pub fn read_latest(&mut self) -> Result<Option<PixelBuffer>> {
        if self.is_closed() {
            return Ok(None);
        }
        let mut latest = None;
        for _ in 0..POOL_FRAMES {
            let Some(frame) = self.take_frame()? else {
                break;
            };
            if let Some(old) = latest.replace(frame) {
                let old: Direct3D11CaptureFrame = old;
                old.Close()?;
            }
        }
        let Some(frame) = latest else {
            return Ok(None);
        };
        let size = frame.ContentSize()?;
        if size != self.size {
            frame.Close()?;
            drop(frame);
            if size.Width <= 0 || size.Height <= 0 {
                return Ok(None);
            }
            frame_dimensions(size)?;
            // Start a fresh session to request an initial frame at the new size. Recreating
            // the pool alone can discard the only frame produced by a static window.
            debug!(
                width = size.Width,
                height = size.Height,
                "restarting Windows capture at the new size"
            );
            self.session.Close()?;
            self.pool.Close()?;
            (self.pool, self.session) = start_capture(&self.device, &self.item, size)?;
            self.size = size;
            self.staging = None;
            return Ok(None);
        }
        let result = self.copy_to_cpu(&frame);
        let closed = frame.Close();
        let data = result?;
        closed?;
        Ok(Some(data))
    }

    fn take_frame(&self) -> Result<Option<Direct3D11CaptureFrame>> {
        let mut frame = ptr::null_mut();
        // SAFETY: the frame pool and its vtable are live. WinRT transfers an owned
        // reference when a frame is available and returns a null pointer when the queue is empty.
        unsafe {
            (self.pool.vtable().TryGetNextFrame)(self.pool.as_raw(), &raw mut frame).ok()?;
            Ok(NonNull::new(frame).map(|frame| Direct3D11CaptureFrame::from_raw(frame.as_ptr())))
        }
    }

    fn copy_to_cpu(&mut self, frame: &Direct3D11CaptureFrame) -> Result<PixelBuffer> {
        let (width, height, bytes) = frame_dimensions(self.size)?;
        let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
        // SAFETY: a capture surface holds a D3D11 texture on the capture device.
        let source: ID3D11Texture2D = unsafe { access.GetInterface()? };
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        // SAFETY: this writes into the fully allocated descriptor.
        unsafe { source.GetDesc(&raw mut desc) };
        if desc.Width != width || desc.Height != height {
            return Err(Error::new(
                E_FAIL,
                "capture texture dimensions differ from the frame pool",
            ));
        }
        if self.staging.is_none() {
            desc.Usage = D3D11_USAGE_STAGING;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
            desc.MiscFlags = 0;
            // SAFETY: the description belongs to the live capture device and has staging flags.
            unsafe {
                self.native_device.CreateTexture2D(
                    &raw const desc,
                    None,
                    Some(&raw mut self.staging),
                )?
            };
        }
        let staging = self
            .staging
            .as_ref()
            .ok_or_else(|| Error::new(E_FAIL, "D3D11 returned no staging texture"))?;
        // SAFETY: both resources have matching dimensions and come from this context's device.
        unsafe { self.context.CopyResource(staging, &source) };
        let mut mapping = D3D11_MAPPED_SUBRESOURCE::default();
        // SAFETY: the staging texture has CPU read access and is used on this thread only.
        unsafe {
            self.context
                .Map(staging, 0, D3D11_MAP_READ, 0, Some(&raw mut mapping))?
        };
        let result = copy_rows(&mapping, width, height, bytes);
        // SAFETY: Map above succeeded and the copied frame holds no pointer into the mapping.
        unsafe { self.context.Unmap(staging, 0) };
        result
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        let _ = self.item.RemoveClosed(self.closed_token);
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

fn start_capture(
    device: &IDirect3DDevice,
    item: &GraphicsCaptureItem,
    size: SizeInt32,
) -> Result<(Direct3D11CaptureFramePool, GraphicsCaptureSession)> {
    let pool =
        Direct3D11CaptureFramePool::CreateFreeThreaded(device, PIXEL_FORMAT, POOL_FRAMES, size)?;
    let session = pool.CreateCaptureSession(item)?;
    session.SetIsCursorCaptureEnabled(false)?;
    session.StartCapture()?;
    Ok((pool, session))
}

fn d3d_device() -> Result<(ID3D11Device, ID3D11DeviceContext)> {
    let mut device = None;
    let mut context = None;
    // SAFETY: uses the default adapter and writes only to local COM pointer storage.
    unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&raw mut device),
            None,
            Some(&raw mut context),
        )?;
    }
    device
        .zip(context)
        .ok_or_else(|| Error::new(E_FAIL, "D3D11 returned no device or immediate context"))
}

fn frame_dimensions(size: SizeInt32) -> Result<(u32, u32, usize)> {
    if size.Width <= 0 || size.Height <= 0 {
        return Err(Error::new(E_INVALIDARG, "capture area is empty"));
    }
    let width = size.Width as u32;
    let height = size.Height as u32;
    let bytes = (width as usize)
        .checked_mul(height as usize)
        .and_then(|pixels| pixels.checked_mul(BYTES_PER_PIXEL))
        .filter(|&bytes| bytes <= isize::MAX as usize)
        .ok_or_else(|| Error::new(E_INVALIDARG, "capture area is too large"))?;
    Ok((width, height, bytes))
}

fn copy_rows(
    mapping: &D3D11_MAPPED_SUBRESOURCE,
    width: u32,
    height: u32,
    bytes: usize,
) -> Result<PixelBuffer> {
    let row = width as usize * BYTES_PER_PIXEL;
    let pitch = mapping.RowPitch as usize;
    if mapping.pData.is_null()
        || pitch < row
        || pitch
            .checked_mul(height as usize)
            .is_none_or(|length| length > isize::MAX as usize)
    {
        return Err(Error::new(
            E_FAIL,
            "D3D11 returned an invalid capture buffer layout",
        ));
    }
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(bytes)
        .map_err(|_| Error::new(E_FAIL, "capture frame allocation failed"))?;
    for y in 0..height as usize {
        // SAFETY: this row lies within the mapped texture, whose row pitch and dimensions were checked.
        let source =
            unsafe { slice::from_raw_parts(mapping.pData.cast::<u8>().add(y * pitch), row) };
        pixels.extend_from_slice(source);
    }
    PixelBuffer::new(PixelSize::new(width, height), PixelFormat::Argb8888, pixels)
        .ok_or_else(|| Error::new(E_FAIL, "capture pixel buffer has an invalid size"))
}

fn target_gone() -> Error {
    Error::new(E_INVALIDARG, "capture target is no longer present")
}

struct Apartment(PhantomData<Rc<()>>);

impl Apartment {
    fn start() -> Result<Self> {
        // SAFETY: Drop balances every successful initialization on the same thread.
        unsafe { RoInitialize(RO_INIT_MULTITHREADED)? };
        Ok(Self(PhantomData))
    }
}

impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: the thread-affine guard is only constructed after RoInitialize succeeds.
        unsafe { RoUninitialize() };
    }
}
