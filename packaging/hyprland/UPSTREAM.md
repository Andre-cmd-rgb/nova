# xwayland:scale, offered to Hyprland

`xwayland-scale.patch` as a pull request to hyprwm/Hyprland, for Andre to read, change and post himself. Nothing here has been posted.

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
- **XWayland's emulated modes** (an X11 game setting its own resolution through RandR) were not tested.
- **The X11 cursor size** is left as it is.
- **An app open through a change** of the scale is reconfigured to its logical size at the new scale; whether it redraws at the new app scale is the toolkit's matter (GTK follows XSETTINGS at once, Qt does not).

## Wiki

In the `xwayland` section of the variables page, after `force_zero_scaling`:

| name | description | type | default |
|---|---|---|---|
| scale | The scale X11 windows draw at on every monitor: 1:1 on monitors of that scale, scaled to the logical size on the others. Set your X11 apps' scale (e.g. `Xft.dpi`, `GDK_SCALE`) to the same number. 0 leaves it to `force_zero_scaling`. | float | 0 |

And in the XWayland page's HiDPI part:

> With monitors of different scales, set `xwayland:scale` to the largest scale, rounded up, and your X11 apps' scale to the same: they are sharp on the monitors of that scale and the same size as Wayland apps on the others, shrunk there.
