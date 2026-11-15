# The shell's part of a theme. Every colour the shell draws is the palette's
# unless a section here or in ~/.config/nova/shell.toml says otherwise (see
# src/shell/Commons/Color.qml and Style.qml for every key and its default),
# so this sets only what the palette alone cannot: borders that follow the
# window border's gradient, when the palette gives Hyprland one, and the
# tooltip's touch of see-through.

[borders]
# The focused window's border, as hyprland.lua draws it, and the same in the
# text colour for the quieter frames.
focused = "{{ shell_gradient hyprland_active_border accent }}"
quiet = "{{ shell_gradient hyprland_active_border foreground }}"

[popups]
border = "borders.focused"

[notifications]
border = "borders.focused"

[polkit]
border = "borders.focused"

[lock]
border-active = "borders.focused"

[menu]
border = "borders.quiet"

[tooltip]
border = "borders.quiet"
background-alpha = 0.97
