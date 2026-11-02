-- How windows, workspaces and the cursor behave.
-- https://wiki.hypr.land/Configuring/Basics/Variables/

hl.config({
  -- A new window splits the focused one on its right or below, and a split
  -- stays the way it was made when its windows change.
  dwindle = { preserve_split = true, force_split = 2 },
  -- Two columns to a screen in the scrolling layout (SUPER + L).
  scrolling = { column_width = 0.49 },
  master = { new_status = "master" },

  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    disable_scale_notification = true,
    -- A window that asks for focus (a link opened in the browser) gets it.
    focus_on_activate = true,
    -- A window is "not responding" after three missed pings, not five.
    anr_missed_pings = 3,
    -- A window that asks for focus while another is fullscreen takes its place.
    on_focus_under_fullscreen = 1,
    -- A window opens on the workspace in view, not the one its program
    -- started from.
    initial_workspace_tracking = 0,
    -- A shell restarted after its lock screen died takes the lock back
    -- (nova-restart-shell), rather than leaving the session unlocked.
    allow_session_lock_restore = true,
  },

  cursor = {
    hide_on_key_press = true,
    warp_on_change_workspace = 1,
  },

  binds = { hide_special_on_workspace_change = true },

  -- Hyprland switches a display to HDR when a fullscreen window asks for it
  -- (an HDR video on YouTube, say), but HDR needs the display at 10 bits per
  -- channel and Nova runs every display at 8: the ThinkPad P1's panel keeps
  -- its framebuffer compression only at 8. The switch then only warned, "wide
  -- color gamut is enabled but the display is not in 10-bit mode", over the
  -- video. Off, the video plays tone-mapped to the display, as in a window.
  render = { cm_auto_hdr = 0 },
})
