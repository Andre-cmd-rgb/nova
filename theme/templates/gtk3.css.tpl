/* Nova palette for GTK 3 apps, and for Qt apps through the gtk3 platform theme.
   Copied to ~/.config/gtk-3.0/nova.css by nova-theme-apply, which links
   gtk.css to it. adw-gtk3, the GTK 3 theme Nova sets, draws with these
   names, libadwaita's, and derives GTK's older ones from them
   (theme_bg_color and the rest), which Qt reads. */
@define-color accent_bg_color {{ accent }};
@define-color accent_fg_color {{ background }};
@define-color accent_color {{ accent }};

@define-color destructive_bg_color {{ red }};
@define-color destructive_fg_color {{ background }};
@define-color destructive_color {{ red }};
@define-color success_bg_color {{ green }};
@define-color success_fg_color {{ background }};
@define-color success_color {{ green }};
@define-color warning_bg_color {{ yellow }};
@define-color warning_fg_color {{ background }};
@define-color warning_color {{ yellow }};
@define-color error_bg_color {{ red }};
@define-color error_fg_color {{ background }};
@define-color error_color {{ red }};

@define-color window_bg_color {{ background }};
@define-color window_fg_color {{ foreground }};
@define-color view_bg_color {{ background }};
@define-color view_fg_color {{ foreground }};

@define-color headerbar_bg_color {{ background }};
@define-color headerbar_fg_color {{ foreground }};
@define-color headerbar_border_color {{ foreground }};
@define-color headerbar_backdrop_color {{ background }};
@define-color headerbar_shade_color rgba({{ dark_background_rgb }}, 0.6);
@define-color headerbar_darker_shade_color rgba({{ darker_background_rgb }}, 0.8);

@define-color sidebar_bg_color {{ dark_background }};
@define-color sidebar_fg_color {{ foreground }};
@define-color sidebar_backdrop_color {{ dark_background }};
@define-color sidebar_border_color {{ mix dark_background foreground 12% }};
@define-color sidebar_shade_color rgba({{ darker_background_rgb }}, 0.4);

@define-color card_bg_color {{ mix background foreground 4% }};
@define-color card_fg_color {{ foreground }};
@define-color card_shade_color rgba({{ darker_background_rgb }}, 0.4);
@define-color thumbnail_bg_color {{ mix background foreground 4% }};
@define-color thumbnail_fg_color {{ foreground }};
@define-color dialog_bg_color {{ background }};
@define-color dialog_fg_color {{ foreground }};
@define-color popover_bg_color {{ background }};
@define-color popover_fg_color {{ foreground }};
@define-color popover_shade_color rgba({{ darker_background_rgb }}, 0.4);

@define-color shade_color rgba({{ darker_background_rgb }}, 0.4);
@define-color scrollbar_outline_color {{ background }};
