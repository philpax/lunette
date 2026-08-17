# Report a fallback from the headset to the simulator

Labels: enhancement

## Current state

A session configured for XR that runs in the desktop simulator gives no indication of the fallback. LÖVR falls back when the headset module cannot start. lunette logs the run as an ordinary startup: the log names the driver, the compositor starts, clients connect, and nothing separates the run from one started on a machine with no headset attached.

One case produced it. An unrelated process held 25 GiB of the GPU's 32 GiB, leaving 1.8 GiB free. Monado created the session and answered `lovr.headset.getName`, because a session needs no large allocation. Every swapchain then failed with `XRT_ERROR_VULKAN`, which is how an allocation failure surfaces through OpenXR. The projection swapchain failed at startup, so the session ran in the simulator. The only evidence was the runtime's own output on stderr:

```
ERROR [swapchain_server_create] ipc_call_swapchain_create failed: XRT_ERROR_VULKAN
XR_ERROR_RUNTIME_FAILURE in xrCreateSwapchain: Failed to create swapchain
```

Establishing the cause required reading the runtime's stderr and then a core dump. A user wearing a headset sees nothing in it and a window on the desktop.

The same exhaustion made a claim's layer swapchain fail, and lunette reports that case. The pool warns once per claim that the runtime refused a composition layer, and the panel degrades to an in-scene quad as [Rendering](../docs/rendering.md) specifies. The gap is in the whole-session case.

## Change

lunette has both facts at startup. `lovr.headset` reports the driver the session started with, and the configuration's `conf.lua` states whether the headset module was requested, so a session that requested XR and is running against the simulator is a state lunette can name rather than one a reader infers.

Report it once, where the frame loop determines which of the two it has. Name the causes that produce it: no runtime, a runtime that refused, or a device with no memory left to allocate from. lunette cannot determine which of these applies, because the OpenXR error is generic, so the message states what lunette observed and leaves the cause open.

Failing instead of falling back is a separate question, and the answer is no. A session in the simulator is still usable, and a user who unplugged a headset does not want a refusal. The silence is the defect; the fallback is correct.

## The teardown fault

The fault at teardown is not lunette's to fix, and is recorded here so it is not diagnosed a second time. With the device in that state, `drain_gpu` reached `lovrGraphicsWait`, which submits before it waits, and the NVIDIA driver faulted inside `gpu_submit` (`vendor/lovr/src/core/gpu_vk.c:3860`) on one run of two. lunette's own path is correct: `drain_gpu` skips the wait when the graphics module is off, and treats a wait that fails as non-fatal. A driver that faults inside a submit cannot be caught from lunette.

## Done when

A session that requested a headset and is running in the simulator reports that state in the log, with what lunette observed, and a session that reached the headset logs nothing new.
