# Themes and backgrounds

One theme colors the whole desktop at once. Pick one, let the adaptive theme take its colors from your photo, or make your own.

<img src="images/themes.jpg" alt="Four copies of the same desktop, a terminal and Settings at Appearance, each in another theme: adaptive, Tokyo Night, Catppuccin Latte with light windows, and Gruvbox" width="100%">

## Choosing a theme

Settings → Appearance, the menu's Style → Theme, Super+Shift+Ctrl+Space, or a terminal:

```sh
nova theme list          # the themes installed
nova theme set nord      # use one
nova theme current       # the one in use
```

Nova has twelve: `adaptive`, `catppuccin`, `catppuccin-latte`, `everforest`, `flexoki-light`, `gruvbox`, `kanagawa`, `miasma`, `nord`, `rose-pine`, `tokyo-night` and `white` (the one a new install starts with).

A theme reaches, at once:

- the shell: bar, menu, panels, notifications, lock screen, and the login screen;
- Hyprland's window borders, and foot with its open windows;
- GTK 4, libadwaita, GTK 3 and Qt apps, light or dark, and Flatpak apps the same way;
- Supernova, Chrome, VS Code, btop and Claude Code;
- the folder icons, in the theme's accent.

The pointer is Nova's own cursor, the same in every theme and every app, the lock screen and the login screen too. For another cursor theme, install it, write `~/.local/share/icons/default/index.theme` with the two lines `[Icon Theme]` and `Inherits=<name>`, and log in again; deleting the file brings Nova's back. The login screen keeps Nova's. The boot menu keeps its own colors.

Open GTK 4 apps follow light and dark at once and take the new colors when opened again; open GTK 3 and Qt apps keep the old theme until they are opened again. Apps that draw themselves (Electron, Flutter, Java) follow light or dark at most.

For CSS of your own, replace the link `~/.config/gtk-4.0/gtk.css` (or `gtk-3.0`) with a file that starts with `@import url("nova.css");`.

## The adaptive theme

The adaptive theme takes its colors from your background, and changes with it.

- The photo gives the tint of surfaces and text, the accent, the border and how vivid the terminal's colors are; the lightness of each color comes from its role, so text always reads.
- A pale photo gives a light theme. Settings → Appearance → **Adaptive theme** keeps it Dark or Light whatever the photo; Auto follows the photo again.

```sh
nova theme adaptive dark         # keep it dark; auto follows the photo again
nova theme palette photo.jpg     # the palette a photo would give, changing nothing
```

## Backgrounds

Each theme offers its own backgrounds, your photos in `~/.config/nova/backgrounds/<theme>/` for that theme alone, and those in `~/.config/nova/backgrounds/` for every theme. Change it in Settings → Appearance, Super+Ctrl+Space, or:

```sh
nova theme bg next             # the next one
nova theme bg set ~/photo.jpg  # this image
```

Each theme remembers its own pick.

## A see-through bar

Settings → Menu Bar → **Transparent**, a double click on an empty part of the bar, or `nova bar transparent toggle`. Over a bright or busy photo, a soft shade sits behind the bar's text so it stays readable.

The terminal is a little see-through too. For a solid one, add to `~/.config/foot/foot.ini`:

```ini
[colors-dark]
alpha=1.0
```

Super+Backspace makes any other window solid, or see-through again.

## Font and text size

- **Font**: Settings → Appearance → Font picks the monospace font of the bar, menu, terminals and code (`nova font list`, `nova font set "<family>"`).
- **Text size**: Settings → Appearance → Text size, 9 to 20 px, everywhere (`nova display text size <px>`).

## Making a theme

A theme is a folder with a `colors.toml` of `key = "value"` color lines. Nova's are in `/usr/share/nova/themes/`; a folder in `~/.config/nova/themes/` is yours. With a new name it is a new theme; with the name of one of Nova's it replaces that theme's files one by one.

```sh
mkdir -p ~/.config/nova/themes
cp -r /usr/share/nova/themes/nord ~/.config/nova/themes/my-theme
nova theme set my-theme      # again after each edit of its colors.toml
```

A theme may also bring files ready-made: `shell.toml` for the shell's look, `icons.theme` for an icon set, `backgrounds/`, or an app's own file (`foot.ini`, `hyprland.lua`) used instead of the one Nova renders. Templates of your own go in `~/.config/nova/templates/<file>.tpl`. `nova theme color --all` prints the palette in use.

**A theme with more than a palette is a program**: Hyprland runs its `hyprland.lua`, and a `foot.ini` can set the terminal's shell. A palette alone is safe, since its values may hold only colors. Install themes only from people you trust.
