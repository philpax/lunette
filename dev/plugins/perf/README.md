# Performance

The performance panel shows frame timing and controls foveated rendering. The Performance action in the wrist menu's Development group opens and closes it, and the header's close button closes it. Whether it is open, the foveation level, and the density overlay are saved when they change.

The plugin applies the saved foveation level, fixed rather than dynamic, and the overlay at start, and restores the headset's previous settings when it stops. Disabling either always succeeds, so the panel reports a level or the overlay as unsupported only after the headset refuses one.

While the panel is open, it samples `lovr.headset.getFrameTiming` every frame into a rolling window and refreshes four times a second. It shows the current, average, and maximum frame interval, work, and prediction, the skipped refreshes in the window, and a graph of the frame interval. Under SteamVR it adds the compositor's GPU and CPU time, dropped and mispresented frames, and whether it is reprojecting. GPU timing is enabled only while the panel is open. The per-pass table reads `lovr.graphics.getTiming` at each refresh, so it covers only the latest submission, and reading it waits for the GPU to finish that submission.

[Options](init.luau)
