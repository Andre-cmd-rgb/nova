# btop in the theme's colours. nova-theme-apply links this as
# ~/.config/btop/themes/nova.theme and tells a running btop to reload.
#
# Text and frames are the palette's plain text, muted and accent. Each meter
# runs from calm to loud as it fills: load and heat end in red, what is free
# or available stays in the cool colours.

theme[main_bg]="{{ background }}"
theme[main_fg]="{{ foreground }}"
theme[title]="{{ bright_foreground }}"
theme[hi_fg]="{{ accent }}"
theme[selected_bg]="{{ lighter_background }}"
theme[selected_fg]="{{ bright_foreground }}"
theme[inactive_fg]="{{ dark_foreground }}"
theme[graph_text]="{{ muted }}"
theme[meter_bg]="{{ lighter_background }}"
theme[proc_misc]="{{ accent }}"
theme[div_line]="{{ lighter_background }}"

theme[cpu_box]="{{ muted }}"
theme[mem_box]="{{ muted }}"
theme[net_box]="{{ muted }}"
theme[proc_box]="{{ muted }}"

theme[cpu_start]="{{ green }}"
theme[cpu_mid]="{{ yellow }}"
theme[cpu_end]="{{ red }}"
theme[temp_start]="{{ cyan }}"
theme[temp_mid]="{{ yellow }}"
theme[temp_end]="{{ red }}"
theme[process_start]="{{ accent }}"
theme[process_mid]="{{ yellow }}"
theme[process_end]="{{ red }}"

theme[used_start]="{{ yellow }}"
theme[used_mid]="{{ orange }}"
theme[used_end]="{{ red }}"
theme[available_start]="{{ cyan }}"
theme[available_mid]="{{ blue }}"
theme[available_end]="{{ blue }}"
theme[cached_start]="{{ blue }}"
theme[cached_mid]="{{ magenta }}"
theme[cached_end]="{{ magenta }}"
theme[free_start]="{{ green }}"
theme[free_mid]="{{ cyan }}"
theme[free_end]="{{ cyan }}"

theme[download_start]="{{ blue }}"
theme[download_mid]="{{ cyan }}"
theme[download_end]="{{ bright_cyan }}"
theme[upload_start]="{{ magenta }}"
theme[upload_mid]="{{ red }}"
theme[upload_end]="{{ bright_red }}"
