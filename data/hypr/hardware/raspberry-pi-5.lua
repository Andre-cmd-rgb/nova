-- Raspberry Pi 5. Its GPU shares the memory with the CPU, so what limits a
-- frame here is the bytes it moves more than its shading: on a 4K screen,
-- each layer drawn into a frame reads and writes 33 MB.

-- Every window opaque (windows.lua): what an opaque window covers is left out
-- of the frame, where under a see-through one the wallpaper and each window
-- below it are drawn as well.
o.opaque_windows = true

-- A frame that misses the screen's refresh starts the next one at once, in a
-- third buffer, instead of waiting out another refresh: a 4K desktop a little
-- too slow for 60 Hz then runs at nearly that, not at 30. It needs the GPU's
-- native fences, which Mesa's V3D driver has (EGL_ANDROID_native_fence_sync).
hl.config({ render = { new_render_scheduling = true } })
