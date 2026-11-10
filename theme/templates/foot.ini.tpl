# The terminal in the theme's colours. The sixteen are the palette's color0
# to color15, in the order Nova's palette engine gives them (background, the
# six colours, foreground; then muted, their bright sides and the brightest
# text). nova-theme-apply links this as ~/.config/foot/theme.ini.
[colors-dark]
background={{ background_strip }}
foreground={{ foreground_strip }}

regular0={{ color0_strip }}
regular1={{ color1_strip }}
regular2={{ color2_strip }}
regular3={{ color3_strip }}
regular4={{ color4_strip }}
regular5={{ color5_strip }}
regular6={{ color6_strip }}
regular7={{ color7_strip }}
bright0={{ color8_strip }}
bright1={{ color9_strip }}
bright2={{ color10_strip }}
bright3={{ color11_strip }}
bright4={{ color12_strip }}
bright5={{ color13_strip }}
bright6={{ color14_strip }}
bright7={{ color15_strip }}

selection-background={{ selection_background_strip }}
selection-foreground={{ selection_foreground_strip }}
cursor={{ background_strip }} {{ cursor_strip }}
urls={{ accent_strip }}
jump-labels={{ background_strip }} {{ accent_strip }}
search-box-match={{ foreground_strip }} {{ lighter_background_strip }}
search-box-no-match={{ background_strip }} {{ red_strip }}
