/* Nova palette for GTK 4 and libadwaita apps (Nautilus, portals, dialogs).
   Linked as ~/.config/gtk-4.0/gtk.css by nova-theme-set. */
:root {
  --accent-bg-color: {{ accent }};
  --accent-fg-color: {{ background }};
  --accent-color: {{ accent }};

  --destructive-bg-color: {{ red }};
  --destructive-fg-color: {{ background }};
  --destructive-color: {{ red }};
  --success-bg-color: {{ green }};
  --success-fg-color: {{ background }};
  --success-color: {{ green }};
  --warning-bg-color: {{ yellow }};
  --warning-fg-color: {{ background }};
  --warning-color: {{ yellow }};
  --error-bg-color: {{ red }};
  --error-fg-color: {{ background }};
  --error-color: {{ red }};

  --window-bg-color: {{ background }};
  --window-fg-color: {{ foreground }};
  --view-bg-color: {{ background }};
  --view-fg-color: {{ foreground }};

  --headerbar-bg-color: {{ background }};
  --headerbar-fg-color: {{ foreground }};
  --headerbar-border-color: {{ foreground }};
  --headerbar-backdrop-color: {{ background }};
  --headerbar-shade-color: rgba({{ dark_background_rgb }}, 0.6);
  --headerbar-darker-shade-color: rgba({{ darker_background_rgb }}, 0.8);

  --sidebar-bg-color: {{ dark_background }};
  --sidebar-fg-color: {{ foreground }};
  --sidebar-backdrop-color: {{ dark_background }};
  --sidebar-border-color: {{ mix dark_background foreground 12% }};
  --sidebar-shade-color: rgba({{ darker_background_rgb }}, 0.4);
  --secondary-sidebar-bg-color: {{ dark_background }};
  --secondary-sidebar-fg-color: {{ foreground }};
  --secondary-sidebar-backdrop-color: {{ dark_background }};
  --secondary-sidebar-border-color: {{ mix dark_background foreground 12% }};
  --secondary-sidebar-shade-color: rgba({{ darker_background_rgb }}, 0.4);

  --card-bg-color: {{ mix background foreground 4% }};
  --card-fg-color: {{ foreground }};
  --card-shade-color: rgba({{ darker_background_rgb }}, 0.4);
  --thumbnail-bg-color: {{ mix background foreground 4% }};
  --thumbnail-fg-color: {{ foreground }};
  --dialog-bg-color: {{ background }};
  --dialog-fg-color: {{ foreground }};
  --popover-bg-color: {{ background }};
  --popover-fg-color: {{ foreground }};
  --popover-shade-color: rgba({{ darker_background_rgb }}, 0.4);

  --shade-color: rgba({{ darker_background_rgb }}, 0.4);
  --scrollbar-outline-color: {{ background }};
}
