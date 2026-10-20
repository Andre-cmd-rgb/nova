-- ThinkPad P1 Gen 4i. The desktop runs on the iGPU (the session pins it in
-- /usr/share/uwsm/env.d/20-nova-thinkpad-p1-gen4i) so the discrete card can be
-- taken off the bus on battery.

-- Video decode and GLX go to the iGPU too. Pointed at the NVIDIA, ordinary apps
-- open the card and hold it awake, and decoding breaks outright once it is off
-- the bus. `thinkpad-power run` points both back for one program.
hl.env("LIBVA_DRIVER_NAME", "iHD")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")

-- A fullscreen window the display controller can read directly skips
-- compositing: no 3840x2400 blit per frame, the largest single thing this GPU
-- does while a video plays. 2 would only engage for surfaces tagged "game"; a
-- video is tagged "video". Hyprland falls back to compositing by itself the
-- moment anything is drawn on top (a notification, the bar, a recorder).
hl.config({ render = { direct_scanout = 1 } })
