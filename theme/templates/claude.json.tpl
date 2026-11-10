{
  "name": "Nova",
  "base": "{{ mode }}",
  "overrides": {
    "text": "{{ foreground }}",
    "inverseText": "{{ background }}",
    "subtle": "{{ muted }}",
    "inactive": "{{ dark_foreground }}",
    "inactiveShimmer": "{{ muted }}",

    "claude": "{{ accent }}",
    "claudeShimmer": "{{ mix accent bright_foreground 40% }}",
    "promptBorder": "{{ muted }}",
    "promptBorderShimmer": "{{ accent }}",
    "permission": "{{ accent }}",
    "permissionShimmer": "{{ mix accent bright_foreground 40% }}",
    "suggestion": "{{ accent }}",
    "rate_limit_fill": "{{ accent }}",
    "rate_limit_empty": "{{ lighter_background }}",
    "briefLabelClaude": "{{ accent }}",
    "briefLabelYou": "{{ cyan }}",

    "planMode": "{{ cyan }}",
    "autoAccept": "{{ magenta }}",
    "bashBorder": "{{ orange }}",
    "ide": "{{ blue }}",
    "remember": "{{ magenta }}",
    "merged": "{{ magenta }}",
    "success": "{{ green }}",
    "warning": "{{ yellow }}",
    "warningShimmer": "{{ mix yellow bright_foreground 40% }}",
    "error": "{{ red }}",

    "diffAdded": "{{ mix background green 18% }}",
    "diffAddedDimmed": "{{ mix background green 9% }}",
    "diffAddedWord": "{{ mix background green 36% }}",
    "diffRemoved": "{{ mix background red 18% }}",
    "diffRemovedDimmed": "{{ mix background red 9% }}",
    "diffRemovedWord": "{{ mix background red 36% }}",

    "userMessageBackground": "{{ lighter_background }}",
    "userMessageBackgroundHover": "{{ mix lighter_background foreground 6% }}",
    "bashMessageBackgroundColor": "{{ lighter_background }}",
    "memoryBackgroundColor": "{{ lighter_background }}",
    "selectionBg": "{{ selection_background }}"
  }
}
