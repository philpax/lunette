# Say why the headset was not reached

Labels: enhancement

## Current state

A session that wanted XR and got the desktop simulator says nothing about why. LÖVR falls back when the headset module cannot start, and lunette logs the fallback as an ordinary startup: the log names the driver, the compositor comes up, clients connect, and nothing distinguishes the run from one where no headset was attached at all.

The case this was found in: the GPU had 1.8 GiB free of 32 GiB, an unrelated process holding 25 GiB. Monado could create the session and answer `lovr.headset.getName` — the session needs no large allocation — and then refused every swapchain with `XRT_ERROR_VULKAN`, which is what an allocation failure surfaces as. The projection swapchain failed at startup, so the session ran in the simulator, and the only evidence was Monado's own line on stderr:

```
ERROR [swapchain_server_create] ipc_call_swapchain_create failed: XRT_ERROR_VULKAN
XR_ERROR_RUNTIME_FAILURE in xrCreateSwapchain: Failed to create swapchain
```

Diagnosing that took reading the runtime's stderr and then a core dump. A user with a headset on sees an empty headset and a window on their desktop.

The same exhaustion made a claim's layer swapchain fail, which lunette does report: the pool warns once per claim that the runtime refused a composition layer, and the panel degrades to an in-scene quad as `docs/rendering.md` says it should. That half is right. It is the whole-session case that is silent.

## Change

lunette knows whether it asked for a headset and whether it got one. `lovr.headset` reports the driver it started with, and the configuration's `conf.lua` says whether the headset module was wanted, so a session that wanted XR and is running against the simulator is a state that can be named at startup rather than inferred.

Report it once, at the point the frame loop learns which it has, naming the likely causes rather than only the fact: no runtime, a runtime that refused, or a device with no memory left to refuse with. What lunette cannot know is why the runtime refused — the OpenXR error is generic — so the message should say what it observed and leave the diagnosis open rather than guess.

Whether to fail instead of falling back is a separate question and probably answered no: a session that drops to the simulator is still usable, and a user who unplugged their headset does not want a refusal. The defect is the silence, not the fallback.

## Not part of this

The teardown fault is not lunette's to fix. With the device in that state, `drain_gpu` reached `lovrGraphicsWait`, which submits before it waits, and the NVIDIA driver faulted inside `gpu_submit` (`vendor/lovr/src/core/gpu_vk.c:3860`) on one run of two. lunette's own path is already correct: `drain_gpu` skips the wait when the graphics module is off and treats a wait that fails as non-fatal. A driver that faults in submit cannot be caught from here, and the crash is recorded in this draft only so the next reader does not diagnose it twice.

## Done when

A session that wanted a headset and is running in the simulator says so in the log, with what it observed, and a session that reached the headset says nothing new.
