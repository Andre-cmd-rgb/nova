{
  "name": "Nova",
  "appearance": "{{ mode }}",
  "canvas": "{{ background }}",
  "accent": "{{ accent }}",
  "colors": {
    "chrome": "{{ background }}",
    "text": "{{ foreground }}",
    "border": "{{ lighter_background }}",
    "focus": "{{ accent }}",
    "error": "{{ red }}",
    "warning": "{{ yellow }}",

    "toolbar": "{{ background }}",
    "toolbarForeground": "{{ foreground }}",
    "toolbarBorder": "{{ lighter_background }}",

    "sidebar": "{{ dark_background }}",
    "sidebarForeground": "{{ light_foreground }}",
    "sidebarBorder": "{{ lighter_background }}",
    "sidebarRowHover": "{{ mix dark_background foreground 5% }}",
    "sidebarRowActive": "{{ mix dark_background accent 15% }}",
    "sidebarRowSelected": "{{ selection }}",

    "codeBackground": "{{ dark_background }}",
    "codeForeground": "{{ foreground }}",

    "terminalBackground": "{{ background }}",
    "terminalForeground": "{{ foreground }}",
    "terminalCursor": "{{ cursor }}",
    "terminalSelection": "{{ selection_background }}",
    "terminalScrollbar": "{{ lighter_background }}",
    "terminalScrollbarHover": "{{ muted }}"
  }
}
