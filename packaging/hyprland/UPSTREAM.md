# Nova's Hyprland patches, offered to Hyprland

Each patch here as a pull request to hyprwm/Hyprland, for Andre to read, change and post himself: `xwayland-scale.patch` first, then `release-bind.patch` ([below](#release-binds-whose-modifier-is-let-go-first)), `xwayland-emulated-modes.patch` ([below](#x11-games-fullscreen-at-the-resolution-they-set)) `xwayland-relative-motion.patch` ([below](#a-pointer-motion-no-mouse-made-comes-with-a-zero-relative-motion)) `groupbar-gradient-column.patch` ([below](#group-bar-gradients-from-textures-one-pixel-wide)) and `stencil-without-depth.patch` ([below](#a-stencil-texture-without-a-depth-buffer)). Nothing here has been posted.

## Before posting

- **Hypr's AI policy:** the patch and this text were written with an AI agent. Read <https://github.com/hyprwm/.github/blob/main/policies/AI_USAGE.md> and the contributing guidelines (<https://wiki.hypr.land/contributing-and-debugging/issue-guidelines/>) first: they ask that a person makes and answers the pull request, and say what has to be disclosed. Rewrite the description below in your own words where the policy asks for it.
- **The wiki:** a new option is documented in hyprwm/hyprland-wiki, with a pull request of its own linked from this one. Its text is at the end.
- **Against main:** the patch is made on the tag v0.57.2. Rebase it on main and run the tests again before opening it (`cmake -DWITH_TESTS=ON`, `hyprland_gtests`).
- **One commit or two:** the monitor lookup fix (below) stands on its own and can go first.

## Title

xwayland: add xwayland:scale, one scale for X11 windows on every monitor

## Description

Fixes the mixed-scale part of #6281.

One X server serves every monitor, and an X11 app draws at one scale. Today there are two choices, and both are wrong on monitors of different scales:

- `force_zero_scaling = false`: X11 windows are 1x, enlarged and blurry on a 2x monitor.
- `force_zero_scaling = true`: X11 coordinates are each monitor's own pixels. An app set to draw at 2x (Xft.dpi, XSETTINGS) is right on the 2x panel and twice its size on a 1x monitor beside it, and 1.33x its size on a 1.5x one.

This adds `xwayland:scale` (float, default 0). When set, X11 coordinates are the logical ones times that scale on every monitor, as GNOME and KDE do it:

- each monitor is told to XWayland (xdg-output logical size, and the row XWayland's outputs are laid out in) at its logical size times the scale; when the scale is the monitor's own, its pixel size, exactly as `force_zero_scaling` does now;
- an X11 window has the same logical size on every monitor, so it does not change size when moved between them;
- it is drawn 1:1 on a monitor of that scale, and scaled to its logical size on the others: shrunk on a lower-scale monitor, enlarged on a higher one. `use_nearest_neighbor` applies only where the window is enlarged, since nearest-neighbour shrinking drops pixels;
- input, popups, menus and override-redirect windows go through the same mapping.

A setup sets the app scale (Xft.dpi, `Gdk/WindowScalingFactor`) to the largest monitor scale, rounded up, and `xwayland:scale` to the same number: X11 apps are then sharp on the main HiDPI panel and the right size everywhere.

With `xwayland:scale = 0` nothing changes: the scale is the monitor's own with `force_zero_scaling`, else 1, as before.

Changing `xwayland:scale` or `force_zero_scaling` at runtime (`hyprctl eval`, a reload) rearranges XWayland's outputs and reconfigures mapped X11 windows, which keep their logical size.

### Also fixed

`waylandToXWaylandCoords` without a monitor finds the monitor nearest a Wayland coordinate. With `force_zero_scaling` it compared that logical coordinate with each monitor's pixel size (`m_transformedSize`), so on a scaled monitor the area it matched was too large. It now uses the logical size.

### How

- `CHyprXWaylandManager::xwaylandScale(monitor)`: the scale of X11 coordinates on a monitor; `xwaylandSize(monitor)`: its size in them. Every place that read `force_zero_scaling` for the mapping (`XWaylandManager` coordinates, `X11Backend` surface scale and client/logical boxes, `XDGOutput` logical size, `MonitorLayoutController`'s unified work area, `MonitorPositionController`'s XWayland row) now asks these.
- `State::xwaylandSizeFor` (with the arrangement, so it is unit tested): the pixel size when the scale is the monitor's own, so 1.6x and other fractional scales keep their exact pixels, else `round(logical × scale)`.
- `PropRefresher::REFRESH_XWAYLAND` on both options calls `refreshScale()`, which does nothing unless a monitor's X11 scale changed.
- `Renderer`: nearest-neighbour for X11 windows only where `surfaceScale() <= monitor scale`.

11 files in `src/`, 97 lines added and 47 removed, and two tests (35 lines).

### Tests

Unit: `MonitorPositionController.xwaylandPositionsUseOneScaleWhenSet` (three monitors at 2x, 1x and 1.5x laid out at X11 scale 2, with and without `force_zero_scaling`) and `xwaylandSizeIsThePixelsAtTheMonitorsOwnScale`. All 855 tests of `hyprland_gtests` pass.

By hand, in a nested Hyprland (a 2560x1600 output at 2x, and beside it a second headless output, 1920x1080 at 1x or 3840x2160 at 1.5x), with an Xlib window, a Qt 6 (xcb) app and a GTK 3 (x11) app at app scale 2, comparing v0.57.2 with `force_zero_scaling = true` against the patch with `xwayland:scale = 2`:

| | v0.57.2 | patched |
|---|---|---|
| a 400x200 (logical at 2x) window opened on the 1x output | 800x400 logical, twice its size | 400x200 |
| the same on the 1.5x output | 534x266 logical | 400x200 |
| moved between outputs | changes size | keeps it |
| on the 2x output | | pixel-identical to v0.57.2 (Xlib, Qt, GTK) |
| a 1-pixel checkerboard on the 2x output | | only black and white: drawn 1:1 |
| clicks at logical +50,+50 and +333,+177 on the 1x and 1.5x outputs | (75,75) and (499,265) X11 px at 1.5x; Qt sees 37.5 and 249.5 | (100,100) and (666,354), the same as on the 2x output; Qt and GTK see 50,50 and 333,177 |
| GTK and Qt menus, a Qt tooltip, an override-redirect popup on the lower output | offset and sized 1.33x (1.5x) or 2x (1x) | the same logical offset and size as on the 2x output |
| X11 layout with 2x + 1.5x at 1280,0 | 2560x1600 + 3840x2160 | 2560x1600 + 5120x2880 |
| `hyprctl eval` setting `xwayland.scale` 0 → 2 → 0 with windows open | | the layout follows, windows keep their logical size and take clicks at the right place |

### Costs and limits

- **Fullscreen on a lower-scale monitor** renders more pixels than the monitor has and shrinks them: 5120x2880 for a 3840x2160 1.5x monitor at scale 2, 3840x2160 for a 1080p 1x one. Direct scanout does not happen there, the buffer not being the mode's size. That is the price of one X11 scale, and the reason the option is off by default.
- **XWayland's emulated modes** (an X11 game setting its own resolution through RandR) are `xwayland-emulated-modes.patch`'s, below.
- **The X11 cursor size** is left as it is.
- **An app open through a change** of the scale is reconfigured to its logical size at the new scale; whether it redraws at the new app scale is the toolkit's matter (GTK follows XSETTINGS at once, Qt does not).

## Wiki

In the `xwayland` section of the variables page, after `force_zero_scaling`:

| name | description | type | default |
|---|---|---|---|
| scale | The scale X11 windows draw at on every monitor: 1:1 on monitors of that scale, scaled to the logical size on the others. Set your X11 apps' scale (e.g. `Xft.dpi`, `GDK_SCALE`) to the same number. 0 leaves it to `force_zero_scaling`. | float | 0 |

And in the XWayland page's HiDPI part:

> With monitors of different scales, set `xwayland:scale` to the largest scale, rounded up, and your X11 apps' scale to the same: they are sharp on the monitors of that scale and the same size as Wayland apps on the others, shrunk there.

# Release binds whose modifier is let go first

`release-bind.patch`, a pull request of its own. The AI policy and the rebase on main above apply to it too.

## Title

keybinds: fire a release bind when its modifier is let go before its key

## Description

A release bind such as `SUPER + D` (`{ release = true }`) does not fire when SUPER is let go before D, however long D was held. Letting go of the modifier first is an ordinary way to end a hold, so a hold-to-talk or hold-to-show bind sometimes never ends.

After any input is let go, `shadowBinds()` shadows every single-key release bind that a still-held input would match. The D still held matches `SUPER + D`'s own release bind, so when D is let go, the bind is shadowed.

That shadowing is meant for an input held around another bind: ALT_L held, `ALT + P` pressed and let go, and ALT_L's own release bind must not fire (`modifierReleaseBindShadowing`). There the input held was pressed before the one let go. An input pressed after it is the other case: the input let go was its modifier. With this change, inputs pressed after the one let go no longer shadow release binds. The pressed list is in the order of the presses, so they are the inputs at the released input's place in it and after.

### Tests

- hyprtester: `releaseBindAfterItsModifierIsReleased` binds `SUPER + K` on release, then lets go of K first and of SUPER first. Each fires once. On v0.57.2 the second does not fire.
- `modifierReleaseBindShadowing`, `modifierReleaseBindAfterScroll` and `mouseReleaseBindShadowing` still pass, and so does the rest of `keybinds.cpp`. Only `keybinds` itself failed here, because it spawns kitty and kitty is not installed.
- All 859 tests of `hyprland_gtests` pass.
- By hand, in a nested Hyprland with `SUPER + D` bound on press and on release, five ways of pressing it all gave one press and one release: held with D let go first, held with SUPER let go first, tapped either way, and both let go within 5 ms. v0.57.2 lost the release in three of the five, each time SUPER was let go first.

# X11 games fullscreen at the resolution they set

`xwayland-emulated-modes.patch`, a pull request of its own. The AI policy and the rebase on main above apply to it too. It asks `xwaylandSize()`, which `xwayland:scale` adds; without that pull request, the size of a monitor in X11 coordinates is `force_zero_scaling ? m_transformedSize : m_size`.

## Title

xwayland: fullscreen a game at the resolution it set through RandR

## Description

An X11 game that sets its own resolution through RandR (exclusive fullscreen: SDL's `SDL_SetWindowFullscreenMode`, Wine) gets no real mode under XWayland. XWayland tells that client alone that the monitor has the mode, and when the client's window is at the monitor's origin and of that size, scales it up to the whole monitor with `wp_viewport`, input included. It names the modes it emulates in the client's windows' `_XWAYLAND_RANDR_EMU_MONITOR_RECTS` (x, y, width, height per monitor, in X11 coordinates), for the window manager to size a fullscreen window by. Mutter and KWin read it.

Hyprland did not, and fullscreened such a window at the monitor's own size: the game drew every pixel of the monitor whatever resolution it was set to, and XWayland never scaled it. Minecraft set to 1280x720 on a 3840x2400 panel (scale 1.6, `force_zero_scaling`, X11 at 2x) drew 4800x3000, 15.6 times the pixels it asked for.

The XWM now reads the property, at map and as it changes, and a window that Hyprland gives the whole of a monitor, as fullscreen does, is configured at the size its client set for that monitor. A change of mode while fullscreen is followed at once. A window whose client set no mode, or that does not cover the monitor, is configured as before.

### Tests

- Unit: `X11EmulatedMode.fullscreenGetsTheModeTheClientSet` and `otherBoxesKeepTheirSize`. All 857 tests of `hyprland_gtests` pass.
- In a nested Hyprland (a 3840x2400 output at 1.6, X11 at 2x with `xwayland:scale`), an SDL3 game on X11 set to exclusive 1280x720: without the patch its window is configured 4800x3000; with it 1280x720, and a picture of the output shows XWayland scaling it to the whole output. 1440x1080 changed to 1280x720 while fullscreen is followed; the output's own mode still gives 4800x3000. A windowed game is unchanged.
- The game's frames in 13 s, drawing a flat picture with vsync off on an Intel GPU, at 1280x720: 3247 to 4005 without the patch, 55799 to 60178 with it.

### Costs and limits

- **The mouse is slower in the game**, as on GNOME and KDE: XWayland scales the pointer's motion by the mode, 1280/4800 here.
- **Direct scanout** does not happen for the scaled window; compositing a 1280x720 buffer costs less than the 4800x3000 one it replaces.

# A pointer motion no mouse made comes with a zero relative motion

`xwayland-relative-motion.patch`, a pull request of its own. The AI policy and the rebase on main above apply to it too.

## Title

xwayland: send a zero relative motion with a pointer motion no mouse made

## Description

XWayland posts a `wl_pointer.motion` whose frame has no `zwp_relative_pointer_v1` motion on an absolute pointer device of its own (`xwayland-pointer`, Abs X and Abs Y), and every other motion on its relative device (`xwayland-relative-pointer`). The X server switches the core pointer's valuators to those of the device that sent last. Hyprland sends motions without a relative one when no mouse moved: a window mapped, tiled or fullscreened under the pointer, a warp, a constraint's cursor hint, an absolute device.

SDL before 3.4.16 reads the core pointer's axes once, at the first raw motion it sees (3.4.16 follows `XI_DeviceChanged`). A game whose window is placed under a still pointer reads the absolute device's axes, and from then on takes each relative raw motion for a position: the first motion of the mouse jumps by the pointer's position, each later one moves by the difference between two motions, and a turned view twitches and comes back. Minecraft 26.3 ships SDL 3.4.14 (LWJGL 3.4.3), and its camera would not turn.

Hyprland now sends XWayland a zero relative motion with a pointer motion that had none in its frame, so XWayland posts every motion on its relative device. The position is the same, the raw motion is zero, and the core pointer's axes stay relative. A mouse's motions are sent as before, and Wayland clients get nothing new. Hyprland already pairs a constraint's warp with a zero relative motion.

### Tests

In a nested Hyprland, an SDL3 game on X11 with SDL 3.4.14, windowed, taking the mouse as Minecraft does (warp to the middle, relative mode) after its window was placed under the pointer, then 300 pixels of mouse motion:

| | without | patched |
|---|---|---|
| relative motion the game got | -2390 in one event, then nothing | 300 |
| raw motions from XWayland's absolute device | 1 of 61 | 0 of 61 |

SDL 3.4.20 gets 300 both ways. Exclusive fullscreen and the menu's cursor are unchanged. All 857 tests of `hyprland_gtests` pass.

### Costs and limits

- **No raw motion for an absolute device's motion** reaches X11 clients: it comes as a zero relative motion. Under a pointer lock Hyprland sends no absolute motion anyway.
- **Mutter and KWin** were not tried; they send motions without a relative one in the same cases, so the same games are likely to break there.

# Group bar gradients from textures one pixel wide

`groupbar-gradient-column.patch`, a pull request of its own. The AI policy and the rebase on main above apply to it too.

## Title

groupbar: render the gradient textures one pixel wide

## Description

With `group:groupbar:gradients` on, `refreshGroupBarGradients()` renders four textures, one for each of `col.active`, `col.inactive`, `col.locked_active` and `col.locked_inactive`, at the size of the focused monitor. The gradient is linear from `(0, 0)` to `(0, height)`, so every column of a texture is the same, and the whole texture is stretched over each tab's box. A texture one pixel wide and as tall draws the same pixels.

A monitor-sized RGBA texture is 35 MiB at 3840x2400, so the four take 140 MiB of graphics memory (160 MiB on Intel, where Mesa rounds each up to 40 MiB). They are made at every config load that touches the group bar's colours and kept, whether or not any window is grouped; a reload frees them and makes them again. One column of 2400 pixels is 9.4 KiB.

The height is left as it was, so a tab samples the gradient exactly as before.

### Tests

In a nested Hyprland (a 3840x2400 output at scale 1.6, `gradients = true`, Mesa's iris on Intel Tiger Lake), the render node's `drm-total-system0` in the compositor's DRM fdinfo:

| | v0.57.2 | patched |
|---|---|---|
| no windows, three runs | 607.6, 607.6, 609.6 MiB | 375.2, 375.2, 375.1 MiB |
| two windows in a group | 850.0 MiB | 697.8 MiB |

A screenshot of the two grouped windows is identical before and after, every pixel of the tabs included (the only pixels that differ are a clock's minute in a panel). Nothing changes with `gradients = false`.

# A stencil texture without a depth buffer

`stencil-without-depth.patch`, a pull request of its own. The AI policy and the rebase on main above apply to it too.

## Title

gl: a stencil-only texture for the monitor stencil on Mesa's iris

## Description

Each monitor has one stencil texture (`CMonitorResources::m_stencilTex`), attached to its blur framebuffer and its work buffers; `renderTextureWithBlur()` draws through it when a surface's `discardMode` needs it (`ignore_alpha` on a layer, blurred popups, input methods). `CGLFramebuffer::internalAlloc()` makes it `GL_DEPTH24_STENCIL8` and attaches it at `GL_DEPTH_STENCIL_ATTACHMENT`, then turns depth testing off: the depth half is never read or written. Mesa's iris stores depth and stencil apart, so the unused depth part was 48 MiB a monitor at 3840x2400 on Intel.

GLES 3.2 has stencil-only textures (`GL_STENCIL_INDEX8`), but a driver may still refuse one as a framebuffer attachment (`GL_FRAMEBUFFER_UNSUPPORTED` is allowed for any combination), and `internalAlloc()` asserts that the framebuffer is complete: a driver that refused it would abort Hyprland at its first framebuffer. So the stencil-only texture is used only where it was measured:

- on a GLES 3.2 context whose EGL display's driver (`EGL_MESA_query_driver`, `eglGetDisplayDriverName`) is `iris`, decided once, at the first framebuffer with a stencil;
- with `GL_NEAREST` filters, as it has no mipmaps for the default minification filter;
- and if a framebuffer with it is not complete, it is detached, the stock `GL_DEPTH24_STENCIL8` texture attached in its place, the GL error cleared and a warning logged, and every framebuffer after it gets the stock texture too, instead of the assertion.

Every other driver (and iris without `EGL_MESA_query_driver`) takes the stock path, unchanged. The detach and the `glInvalidateFramebuffer` calls name `GL_DEPTH_STENCIL_ATTACHMENT`, which covers a stencil-only attachment too.

### Tests

In a nested Hyprland (a 3840x2400 output at scale 1.6, Mesa 26.3's iris on Intel Tiger Lake, GLES 3.2), the render node's `drm-total-system0` in the compositor's DRM fdinfo:

| | v0.57.2 (with the group bar patch) | patched |
|---|---|---|
| at rest | 375.2, 375.2 MiB | 321.1, 321.2, 321.0, 321.2, 361.1 MiB |
| `layerrule = blur` and `ignore_alpha` on every layer | 455.3 MiB | 401.4 MiB |

(The 40 MiB in one run is a buffer of Mesa's, there or not by timing.) The log says `Framebuffer stencil: stencil-only (EGL driver iris)`. With blur and `ignore_alpha` on every layer, so that blur draws through the stencil, fifteen screenshots of each (a desktop with a panel, menus, full-screen overlays, the lock screen's preview) are the same before and after: the only pixels more than one level of 255 apart are a clock's minute.

The fallback, forced in a test build that made the stencil-only texture 0x0: the log says `Framebuffer "Monitor WAYLAND-1 blur FB": a stencil-only texture made it incomplete (FB status: 36054, GL Error: 0x0), depth and stencil from now on`, Hyprland goes on instead of aborting, it uses 455.4 MiB with blur on every layer (as v0.57.2), and its screenshots are within one level of 255 of v0.57.2's.

On zink over Intel's Vulkan driver (`MESA_LOADER_DRIVER_OVERRIDE=zink`), the log says `Framebuffer stencil: depth and stencil (EGL driver zink)`, and the desktop draws as before. Other drivers were not run; they take the stock path.
