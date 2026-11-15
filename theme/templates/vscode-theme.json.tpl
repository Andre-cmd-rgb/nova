{
  "name": "Nova",
  "$schema": "vscode://schemas/color-theme",
  "type": "{{ mode }}",
  "semanticHighlighting": true,
  "colors": {
    "activityBar.activeBorder": "{{ accent }}",
    "activityBar.background": "{{ dark_background }}",
    "activityBar.border": "{{ mix background foreground 12% }}",
    "activityBar.foreground": "{{ foreground }}",
    "activityBar.inactiveForeground": "{{ muted }}",
    "activityBarBadge.background": "{{ accent }}",
    "activityBarBadge.foreground": "{{ background }}",
    "activityBarTop.activeBorder": "{{ accent }}",
    "activityBarTop.foreground": "{{ foreground }}",
    "activityBarTop.inactiveForeground": "{{ muted }}",
    "badge.background": "{{ accent }}",
    "badge.foreground": "{{ background }}",
    "banner.background": "{{ lighter_background }}",
    "banner.foreground": "{{ foreground }}",
    "banner.iconForeground": "{{ accent }}",
    "breadcrumb.activeSelectionForeground": "{{ bright_foreground }}",
    "breadcrumb.focusForeground": "{{ foreground }}",
    "breadcrumb.foreground": "{{ muted }}",
    "button.background": "{{ accent }}",
    "button.foreground": "{{ background }}",
    "button.hoverBackground": "{{ mix accent foreground 15% }}",
    "button.secondaryBackground": "{{ lighter_background }}",
    "button.secondaryHoverBackground": "{{ mix lighter_background foreground 10% }}",
    "button.separator": "{{ background }}66",
    "charts.green": "{{ green }}",
    "charts.lines": "{{ mix background foreground 12% }}",
    "charts.orange": "{{ orange }}",
    "charts.purple": "{{ magenta }}",
    "chat.requestBackground": "{{ dark_background }}",
    "chat.requestBorder": "{{ mix background foreground 12% }}",
    "chat.slashCommandBackground": "{{ lighter_background }}",
    "chat.slashCommandForeground": "{{ accent }}",
    "checkbox.selectBorder": "{{ accent }}",
    "commandCenter.activeBackground": "{{ mix background foreground 6% }}",
    "commandCenter.background": "{{ background }}",
    "commandCenter.border": "{{ mix background foreground 12% }}",
    "commandCenter.foreground": "{{ light_foreground }}",
    "contrastBorder": "#00000000",
    "debugConsole.errorForeground": "{{ red }}",
    "debugConsole.sourceForeground": "{{ light_foreground }}",
    "debugExceptionWidget.background": "{{ dark_background }}",
    "debugExceptionWidget.border": "{{ red }}",
    "debugIcon.breakpointForeground": "{{ red }}",
    "debugIcon.continueForeground": "{{ green }}",
    "debugIcon.pauseForeground": "{{ yellow }}",
    "debugIcon.restartForeground": "{{ green }}",
    "debugIcon.startForeground": "{{ green }}",
    "debugIcon.stepIntoForeground": "{{ blue }}",
    "debugIcon.stepOutForeground": "{{ blue }}",
    "debugIcon.stepOverForeground": "{{ blue }}",
    "debugIcon.stopForeground": "{{ red }}",
    "debugToolBar.background": "{{ dark_background }}",
    "debugToolBar.border": "{{ mix background foreground 12% }}",
    "descriptionForeground": "{{ muted }}",
    "diffEditor.border": "{{ mix background foreground 12% }}",
    "diffEditor.diagonalFill": "{{ mix background foreground 12% }}",
    "diffEditor.insertedLineBackground": "{{ green }}14",
    "diffEditor.insertedTextBackground": "{{ green }}26",
    "diffEditor.removedLineBackground": "{{ red }}14",
    "diffEditor.removedTextBackground": "{{ red }}26",
    "diffEditorGutter.insertedLineBackground": "{{ green }}26",
    "diffEditorGutter.removedLineBackground": "{{ red }}26",
    "disabledForeground": "{{ dark_foreground }}",
    "dropdown.background": "{{ dark_background }}",
    "dropdown.border": "{{ mix background foreground 12% }}",
    "dropdown.foreground": "{{ foreground }}",
    "dropdown.listBackground": "{{ background }}",
    "editor.background": "{{ background }}",
    "editor.findMatchBackground": "{{ orange }}55",
    "editor.findMatchBorder": "{{ orange }}",
    "editor.findMatchHighlightBackground": "{{ orange }}2a",
    "editor.findRangeHighlightBackground": "{{ accent }}14",
    "editor.foreground": "{{ foreground }}",
    "editor.hoverHighlightBackground": "{{ accent }}22",
    "editor.inactiveSelectionBackground": "{{ selection_background }}88",
    "editor.lineHighlightBackground": "{{ mix background foreground 4% }}",
    "editor.lineHighlightBorder": "#00000000",
    "editor.linkedEditingBackground": "{{ accent }}22",
    "editor.rangeHighlightBackground": "{{ accent }}14",
    "editor.selectionBackground": "{{ selection_background }}",
    "editor.selectionHighlightBackground": "{{ selection_background }}66",
    "editor.wordHighlightBackground": "{{ selection_background }}55",
    "editor.wordHighlightStrongBackground": "{{ selection_background }}88",
    "editorBracketHighlight.foreground1": "{{ yellow }}",
    "editorBracketHighlight.foreground2": "{{ magenta }}",
    "editorBracketHighlight.foreground3": "{{ blue }}",
    "editorBracketHighlight.foreground4": "{{ cyan }}",
    "editorBracketHighlight.foreground5": "{{ green }}",
    "editorBracketHighlight.foreground6": "{{ orange }}",
    "editorBracketHighlight.unexpectedBracket.foreground": "{{ red }}",
    "editorBracketMatch.background": "{{ accent }}22",
    "editorBracketMatch.border": "{{ accent }}88",
    "editorCodeLens.foreground": "{{ muted }}",
    "editorCursor.foreground": "{{ cursor }}",
    "editorError.foreground": "{{ red }}",
    "editorGhostText.foreground": "{{ muted }}",
    "editorGroup.border": "{{ mix background foreground 12% }}",
    "editorGroup.dropBackground": "{{ accent }}22",
    "editorGroupHeader.border": "{{ mix background foreground 12% }}",
    "editorGroupHeader.tabsBackground": "{{ dark_background }}",
    "editorGroupHeader.tabsBorder": "{{ mix background foreground 12% }}",
    "editorGutter.addedBackground": "{{ green }}",
    "editorGutter.foldingControlForeground": "{{ muted }}",
    "editorGutter.modifiedBackground": "{{ blue }}",
    "editorHint.foreground": "{{ green }}",
    "editorHoverWidget.statusBarBackground": "{{ dark_background }}",
    "editorIndentGuide.activeBackground1": "{{ mix background foreground 22% }}",
    "editorIndentGuide.background1": "{{ mix background foreground 8% }}",
    "editorInfo.foreground": "{{ blue }}",
    "editorInlayHint.background": "{{ lighter_background }}aa",
    "editorInlayHint.foreground": "{{ muted }}",
    "editorLightBulb.foreground": "{{ yellow }}",
    "editorLightBulbAutoFix.foreground": "{{ blue }}",
    "editorLineNumber.activeForeground": "{{ light_foreground }}",
    "editorLineNumber.foreground": "{{ dark_foreground }}",
    "editorLink.activeForeground": "{{ accent }}",
    "editorMarkerNavigation.background": "{{ dark_background }}",
    "editorMarkerNavigationError.background": "{{ red }}",
    "editorMarkerNavigationInfo.background": "{{ blue }}",
    "editorMarkerNavigationWarning.background": "{{ yellow }}",
    "editorOverviewRuler.addedForeground": "{{ green }}99",
    "editorOverviewRuler.border": "#00000000",
    "editorOverviewRuler.deletedForeground": "{{ red }}99",
    "editorOverviewRuler.errorForeground": "{{ red }}",
    "editorOverviewRuler.findMatchForeground": "{{ orange }}99",
    "editorOverviewRuler.modifiedForeground": "{{ blue }}99",
    "editorOverviewRuler.selectionHighlightForeground": "{{ accent }}66",
    "editorRuler.foreground": "{{ mix background foreground 12% }}",
    "editorStickyScroll.shadow": "#00000040",
    "editorStickyScrollHover.background": "{{ mix background foreground 6% }}",
    "editorSuggestWidget.focusHighlightForeground": "{{ accent }}",
    "editorUnnecessaryCode.opacity": "#000000aa",
    "editorWarning.foreground": "{{ yellow }}",
    "editorWhitespace.foreground": "{{ mix background foreground 18% }}",
    "editorWidget.background": "{{ dark_background }}",
    "editorWidget.border": "{{ mix background foreground 12% }}",
    "editorWidget.resizeBorder": "{{ accent }}",
    "errorForeground": "{{ red }}",
    "extensionBadge.remoteForeground": "{{ background }}",
    "extensionButton.prominentForeground": "{{ background }}",
    "extensionButton.prominentHoverBackground": "{{ mix accent foreground 15% }}",
    "extensionIcon.preReleaseForeground": "{{ orange }}",
    "extensionIcon.starForeground": "{{ yellow }}",
    "focusBorder": "{{ accent }}99",
    "foreground": "{{ foreground }}",
    "gitDecoration.addedResourceForeground": "{{ green }}",
    "gitDecoration.conflictingResourceForeground": "{{ orange }}",
    "gitDecoration.deletedResourceForeground": "{{ red }}",
    "gitDecoration.ignoredResourceForeground": "{{ dark_foreground }}",
    "gitDecoration.modifiedResourceForeground": "{{ blue }}",
    "gitDecoration.renamedResourceForeground": "{{ cyan }}",
    "gitDecoration.stageDeletedResourceForeground": "{{ red }}",
    "gitDecoration.stageModifiedResourceForeground": "{{ blue }}",
    "gitDecoration.submoduleResourceForeground": "{{ magenta }}",
    "gitDecoration.untrackedResourceForeground": "{{ green }}",
    "icon.foreground": "{{ light_foreground }}",
    "inlineChatInput.background": "{{ background }}",
    "inlineChatInput.focusBorder": "{{ accent }}",
    "input.background": "{{ dark_background }}",
    "input.border": "{{ mix background foreground 12% }}",
    "input.placeholderForeground": "{{ muted }}",
    "inputOption.activeBackground": "{{ accent }}33",
    "inputOption.activeBorder": "{{ accent }}",
    "inputOption.activeForeground": "{{ bright_foreground }}",
    "inputValidation.errorBackground": "{{ background }}",
    "inputValidation.errorBorder": "{{ red }}",
    "inputValidation.infoBackground": "{{ background }}",
    "inputValidation.infoBorder": "{{ blue }}",
    "inputValidation.warningBackground": "{{ background }}",
    "inputValidation.warningBorder": "{{ yellow }}",
    "keybindingLabel.background": "{{ lighter_background }}",
    "keybindingLabel.border": "{{ mix background foreground 12% }}",
    "keybindingLabel.bottomBorder": "{{ mix background foreground 12% }}",
    "keybindingLabel.foreground": "{{ foreground }}",
    "list.activeSelectionBackground": "{{ mix background accent 18% }}",
    "list.activeSelectionForeground": "{{ bright_foreground }}",
    "list.deemphasizedForeground": "{{ muted }}",
    "list.dropBackground": "{{ mix background accent 18% }}",
    "list.errorForeground": "{{ red }}",
    "list.focusBackground": "{{ mix background accent 18% }}",
    "list.focusHighlightForeground": "{{ accent }}",
    "list.focusOutline": "{{ accent }}66",
    "list.highlightForeground": "{{ accent }}",
    "list.hoverBackground": "{{ mix background foreground 6% }}",
    "list.hoverForeground": "{{ foreground }}",
    "list.inactiveSelectionBackground": "{{ mix background foreground 6% }}",
    "list.inactiveSelectionForeground": "{{ foreground }}",
    "list.invalidItemForeground": "{{ red }}",
    "list.warningForeground": "{{ yellow }}",
    "listFilterWidget.background": "{{ background }}",
    "listFilterWidget.noMatchesOutline": "{{ red }}",
    "listFilterWidget.outline": "{{ accent }}",
    "menu.background": "{{ background }}",
    "menu.border": "{{ mix background foreground 12% }}",
    "menu.separatorBackground": "{{ mix background foreground 12% }}",
    "menubar.selectionBackground": "{{ mix background foreground 6% }}",
    "menubar.selectionForeground": "{{ bright_foreground }}",
    "merge.commonContentBackground": "{{ muted }}22",
    "merge.commonHeaderBackground": "{{ muted }}55",
    "merge.currentContentBackground": "{{ green }}22",
    "merge.currentHeaderBackground": "{{ green }}55",
    "merge.incomingContentBackground": "{{ blue }}22",
    "merge.incomingHeaderBackground": "{{ blue }}55",
    "minimap.background": "{{ background }}",
    "minimap.errorHighlight": "{{ red }}aa",
    "minimap.findMatchHighlight": "{{ orange }}aa",
    "minimap.selectionHighlight": "{{ accent }}66",
    "minimap.warningHighlight": "{{ yellow }}aa",
    "minimapSlider.activeBackground": "{{ muted }}44",
    "minimapSlider.background": "{{ muted }}22",
    "minimapSlider.hoverBackground": "{{ muted }}33",
    "notebook.cellBorderColor": "{{ mix background foreground 12% }}",
    "notebook.cellHoverBackground": "{{ mix background foreground 6% }}",
    "notebook.focusedCellBorder": "{{ accent }}88",
    "notebook.outputContainerBackgroundColor": "{{ dark_background }}",
    "notificationCenterHeader.background": "{{ dark_background }}",
    "notificationCenterHeader.foreground": "{{ foreground }}",
    "notifications.border": "{{ mix background foreground 12% }}",
    "panel.border": "{{ mix background foreground 12% }}",
    "panelInput.border": "{{ mix background foreground 12% }}",
    "panelSectionHeader.background": "{{ dark_background }}",
    "panelTitle.activeBorder": "{{ accent }}",
    "panelTitle.activeForeground": "{{ foreground }}",
    "panelTitle.inactiveForeground": "{{ muted }}",
    "peekView.border": "{{ accent }}",
    "peekViewEditor.background": "{{ dark_background }}",
    "peekViewEditor.matchHighlightBackground": "{{ orange }}44",
    "peekViewResult.background": "{{ dark_background }}",
    "peekViewResult.fileForeground": "{{ foreground }}",
    "peekViewResult.lineForeground": "{{ light_foreground }}",
    "peekViewResult.matchHighlightBackground": "{{ orange }}44",
    "peekViewResult.selectionBackground": "{{ mix background accent 18% }}",
    "peekViewResult.selectionForeground": "{{ bright_foreground }}",
    "peekViewTitle.background": "{{ dark_background }}",
    "peekViewTitleDescription.foreground": "{{ muted }}",
    "peekViewTitleLabel.foreground": "{{ foreground }}",
    "pickerGroup.border": "{{ mix background foreground 12% }}",
    "pickerGroup.foreground": "{{ accent }}",
    "progressBar.background": "{{ accent }}",
    "quickInputList.focusBackground": "{{ mix background accent 18% }}",
    "quickInputTitle.background": "{{ dark_background }}",
    "sash.hoverBorder": "{{ accent }}",
    "scrollbar.shadow": "#00000000",
    "scrollbarSlider.activeBackground": "{{ muted }}77",
    "scrollbarSlider.background": "{{ muted }}33",
    "scrollbarSlider.hoverBackground": "{{ muted }}55",
    "selection.background": "{{ selection_background }}",
    "settings.focusedRowBackground": "{{ mix background foreground 6% }}",
    "settings.focusedRowBorder": "{{ accent }}66",
    "settings.headerForeground": "{{ foreground }}",
    "settings.modifiedItemIndicator": "{{ accent }}",
    "settings.rowHoverBackground": "{{ mix background foreground 6% }}",
    "sideBar.background": "{{ dark_background }}",
    "sideBar.border": "{{ mix background foreground 12% }}",
    "sideBar.foreground": "{{ light_foreground }}",
    "sideBarSectionHeader.background": "{{ dark_background }}",
    "sideBarSectionHeader.border": "{{ mix background foreground 12% }}",
    "sideBarSectionHeader.foreground": "{{ foreground }}",
    "sideBarTitle.foreground": "{{ foreground }}",
    "statusBar.background": "{{ dark_background }}",
    "statusBar.border": "{{ mix background foreground 12% }}",
    "statusBar.debuggingBackground": "{{ orange }}",
    "statusBar.debuggingForeground": "{{ background }}",
    "statusBar.focusBorder": "{{ accent }}",
    "statusBar.foreground": "{{ light_foreground }}",
    "statusBar.noFolderBackground": "{{ dark_background }}",
    "statusBarItem.activeBackground": "{{ mix background accent 18% }}",
    "statusBarItem.errorBackground": "{{ red }}",
    "statusBarItem.errorForeground": "{{ background }}",
    "statusBarItem.focusBorder": "{{ accent }}",
    "statusBarItem.hoverBackground": "{{ mix background foreground 6% }}",
    "statusBarItem.prominentBackground": "{{ lighter_background }}",
    "statusBarItem.prominentForeground": "{{ foreground }}",
    "statusBarItem.remoteForeground": "{{ background }}",
    "statusBarItem.warningBackground": "{{ yellow }}",
    "statusBarItem.warningForeground": "{{ background }}",
    "symbolIcon.arrayForeground": "{{ orange }}",
    "symbolIcon.booleanForeground": "{{ orange }}",
    "symbolIcon.classForeground": "{{ yellow }}",
    "symbolIcon.colorForeground": "{{ magenta }}",
    "symbolIcon.constantForeground": "{{ orange }}",
    "symbolIcon.constructorForeground": "{{ blue }}",
    "symbolIcon.enumeratorForeground": "{{ yellow }}",
    "symbolIcon.enumeratorMemberForeground": "{{ orange }}",
    "symbolIcon.eventForeground": "{{ red }}",
    "symbolIcon.fieldForeground": "{{ cyan }}",
    "symbolIcon.folderForeground": "{{ light_foreground }}",
    "symbolIcon.functionForeground": "{{ blue }}",
    "symbolIcon.interfaceForeground": "{{ yellow }}",
    "symbolIcon.keyForeground": "{{ cyan }}",
    "symbolIcon.keywordForeground": "{{ magenta }}",
    "symbolIcon.methodForeground": "{{ blue }}",
    "symbolIcon.moduleForeground": "{{ yellow }}",
    "symbolIcon.namespaceForeground": "{{ yellow }}",
    "symbolIcon.nullForeground": "{{ orange }}",
    "symbolIcon.numberForeground": "{{ orange }}",
    "symbolIcon.objectForeground": "{{ yellow }}",
    "symbolIcon.operatorForeground": "{{ cyan }}",
    "symbolIcon.packageForeground": "{{ yellow }}",
    "symbolIcon.propertyForeground": "{{ cyan }}",
    "symbolIcon.referenceForeground": "{{ blue }}",
    "symbolIcon.snippetForeground": "{{ green }}",
    "symbolIcon.stringForeground": "{{ green }}",
    "symbolIcon.structForeground": "{{ yellow }}",
    "symbolIcon.typeParameterForeground": "{{ yellow }}",
    "symbolIcon.unitForeground": "{{ orange }}",
    "symbolIcon.variableForeground": "{{ foreground }}",
    "tab.activeBorder": "{{ background }}",
    "tab.activeBorderTop": "{{ accent }}",
    "tab.activeForeground": "{{ bright_foreground }}",
    "tab.border": "{{ mix background foreground 12% }}",
    "tab.dragAndDropBorder": "{{ accent }}",
    "tab.hoverBackground": "{{ mix background foreground 6% }}",
    "tab.hoverForeground": "{{ foreground }}",
    "tab.inactiveBackground": "{{ dark_background }}",
    "tab.inactiveForeground": "{{ muted }}",
    "tab.unfocusedActiveBorderTop": "{{ mix background foreground 12% }}",
    "tab.unfocusedActiveForeground": "{{ light_foreground }}",
    "tab.unfocusedInactiveForeground": "{{ muted }}",
    "terminal.ansiBlack": "{{ color0 }}",
    "terminal.ansiBlue": "{{ color4 }}",
    "terminal.ansiBrightBlack": "{{ color8 }}",
    "terminal.ansiBrightBlue": "{{ color12 }}",
    "terminal.ansiBrightCyan": "{{ color14 }}",
    "terminal.ansiBrightGreen": "{{ color10 }}",
    "terminal.ansiBrightMagenta": "{{ color13 }}",
    "terminal.ansiBrightRed": "{{ color9 }}",
    "terminal.ansiBrightWhite": "{{ color15 }}",
    "terminal.ansiBrightYellow": "{{ color11 }}",
    "terminal.ansiCyan": "{{ color6 }}",
    "terminal.ansiGreen": "{{ color2 }}",
    "terminal.ansiMagenta": "{{ color5 }}",
    "terminal.ansiRed": "{{ color1 }}",
    "terminal.ansiWhite": "{{ color7 }}",
    "terminal.ansiYellow": "{{ color3 }}",
    "terminal.background": "{{ background }}",
    "terminal.foreground": "{{ foreground }}",
    "terminalCommandDecoration.defaultBackground": "{{ muted }}",
    "terminalCommandDecoration.errorBackground": "{{ red }}",
    "terminalCommandDecoration.successBackground": "{{ green }}",
    "terminalCursor.background": "{{ background }}",
    "terminalCursor.foreground": "{{ cursor }}",
    "testing.iconPassed": "{{ green }}",
    "testing.iconSkipped": "{{ muted }}",
    "textBlockQuote.background": "{{ dark_background }}",
    "textBlockQuote.border": "{{ accent }}",
    "textCodeBlock.background": "{{ dark_background }}",
    "textLink.activeForeground": "{{ bright_blue }}",
    "textLink.foreground": "{{ accent }}",
    "textPreformat.foreground": "{{ cyan }}",
    "textSeparator.foreground": "{{ mix background foreground 12% }}",
    "titleBar.activeBackground": "{{ dark_background }}",
    "titleBar.activeForeground": "{{ foreground }}",
    "titleBar.border": "{{ mix background foreground 12% }}",
    "titleBar.inactiveBackground": "{{ dark_background }}",
    "titleBar.inactiveForeground": "{{ muted }}",
    "tree.inactiveIndentGuidesStroke": "{{ mix background foreground 6% }}",
    "tree.indentGuidesStroke": "{{ mix background foreground 12% }}",
    "walkThrough.embeddedEditorBackground": "{{ dark_background }}",
    "welcomePage.background": "{{ background }}",
    "welcomePage.tileBorder": "{{ mix background foreground 12% }}",
    "welcomePage.tileHoverBackground": "{{ mix background foreground 6% }}",
    "widget.border": "{{ mix background foreground 12% }}",
    "widget.shadow": "#00000040"
  },
  "tokenColors": [
    {
      "name": "Comments",
      "scope": [
        "comment",
        "punctuation.definition.comment",
        "string.comment"
      ],
      "settings": {
        "foreground": "{{ muted }}",
        "fontStyle": "italic"
      }
    },
    {
      "name": "Documentation tags",
      "scope": [
        "comment keyword.codetag",
        "comment storage.type",
        "comment entity.name.type",
        "comment.block.documentation keyword",
        "comment.block.documentation storage"
      ],
      "settings": {
        "foreground": "{{ dark_foreground }}",
        "fontStyle": "italic"
      }
    },
    {
      "name": "Keywords",
      "scope": [
        "keyword",
        "keyword.control",
        "storage",
        "storage.type",
        "storage.modifier",
        "keyword.other.using",
        "keyword.other.import",
        "keyword.operator.new",
        "keyword.operator.expression",
        "keyword.operator.logical.python"
      ],
      "settings": {
        "foreground": "{{ magenta }}"
      }
    },
    {
      "name": "Operators",
      "scope": [
        "keyword.operator",
        "punctuation.accessor",
        "punctuation.separator.key-value"
      ],
      "settings": {
        "foreground": "{{ cyan }}"
      }
    },
    {
      "name": "Punctuation",
      "scope": [
        "punctuation",
        "meta.brace",
        "punctuation.definition.tag",
        "punctuation.section.embedded"
      ],
      "settings": {
        "foreground": "{{ light_foreground }}"
      }
    },
    {
      "name": "Functions",
      "scope": [
        "entity.name.function",
        "meta.function-call entity.name.function",
        "support.function",
        "meta.method-call",
        "entity.name.method",
        "variable.function",
        "support.function.builtin"
      ],
      "settings": {
        "foreground": "{{ blue }}"
      }
    },
    {
      "name": "Types",
      "scope": [
        "entity.name.type",
        "entity.name.class",
        "entity.name.struct",
        "entity.name.enum",
        "entity.name.interface",
        "entity.other.inherited-class",
        "support.type",
        "support.class",
        "storage.type.primitive",
        "storage.type.built-in",
        "entity.name.namespace",
        "entity.name.module",
        "entity.name.type.module"
      ],
      "settings": {
        "foreground": "{{ yellow }}"
      }
    },
    {
      "name": "Strings",
      "scope": [
        "string",
        "string.quoted",
        "string.template",
        "punctuation.definition.string",
        "markup.inline.raw",
        "markup.fenced_code"
      ],
      "settings": {
        "foreground": "{{ green }}"
      }
    },
    {
      "name": "Escapes and patterns",
      "scope": [
        "constant.character.escape",
        "string.regexp",
        "constant.other.placeholder",
        "constant.character.format.placeholder"
      ],
      "settings": {
        "foreground": "{{ cyan }}"
      }
    },
    {
      "name": "Fixed values",
      "scope": [
        "constant",
        "constant.numeric",
        "constant.language",
        "constant.character",
        "variable.other.constant",
        "variable.other.enummember",
        "support.constant",
        "keyword.other.unit"
      ],
      "settings": {
        "foreground": "{{ orange }}"
      }
    },
    {
      "name": "Variables",
      "scope": [
        "variable",
        "variable.other",
        "variable.other.readwrite",
        "meta.definition.variable"
      ],
      "settings": {
        "foreground": "{{ foreground }}"
      }
    },
    {
      "name": "Language variables",
      "scope": [
        "variable.language",
        "variable.language.this",
        "variable.language.self",
        "variable.language.super"
      ],
      "settings": {
        "foreground": "{{ red }}",
        "fontStyle": "italic"
      }
    },
    {
      "name": "Parameters",
      "scope": [
        "variable.parameter",
        "meta.function.parameters variable",
        "entity.name.variable.parameter"
      ],
      "settings": {
        "foreground": "{{ light_foreground }}",
        "fontStyle": "italic"
      }
    },
    {
      "name": "Properties",
      "scope": [
        "variable.other.property",
        "variable.other.object.property",
        "support.variable.property",
        "meta.object-literal.key",
        "entity.name.tag.yaml",
        "support.type.property-name",
        "entity.other.attribute-name.css",
        "support.type.property-name.css"
      ],
      "settings": {
        "foreground": "{{ cyan }}"
      }
    },
    {
      "name": "Decorators and macros",
      "scope": [
        "meta.decorator",
        "entity.name.function.decorator",
        "punctuation.decorator",
        "entity.name.function.macro",
        "support.function.macro",
        "entity.name.function.preprocessor",
        "meta.preprocessor"
      ],
      "settings": {
        "foreground": "{{ orange }}"
      }
    },
    {
      "name": "Tags",
      "scope": [
        "entity.name.tag",
        "meta.tag.sgml",
        "markup.deleted.git_gutter"
      ],
      "settings": {
        "foreground": "{{ red }}"
      }
    },
    {
      "name": "Attributes",
      "scope": [
        "entity.other.attribute-name",
        "entity.other.attribute-name.html"
      ],
      "settings": {
        "foreground": "{{ yellow }}",
        "fontStyle": "italic"
      }
    },
    {
      "name": "CSS selectors",
      "scope": [
        "entity.other.attribute-name.class.css",
        "entity.other.attribute-name.id.css",
        "entity.name.tag.css",
        "entity.other.attribute-name.pseudo-class.css"
      ],
      "settings": {
        "foreground": "{{ yellow }}"
      }
    },
    {
      "name": "Shell variables",
      "scope": [
        "variable.other.normal.shell",
        "variable.other.special.shell",
        "punctuation.definition.variable.shell"
      ],
      "settings": {
        "foreground": "{{ cyan }}"
      }
    },
    {
      "name": "Invalid",
      "scope": [
        "invalid",
        "invalid.illegal"
      ],
      "settings": {
        "foreground": "{{ red }}"
      }
    },
    {
      "name": "Deprecated",
      "scope": [
        "invalid.deprecated"
      ],
      "settings": {
        "foreground": "{{ orange }}",
        "fontStyle": "strikethrough"
      }
    },
    {
      "name": "Headings",
      "scope": [
        "markup.heading",
        "entity.name.section",
        "markup.heading punctuation.definition.heading"
      ],
      "settings": {
        "foreground": "{{ blue }}",
        "fontStyle": "bold"
      }
    },
    {
      "name": "Bold",
      "scope": [
        "markup.bold"
      ],
      "settings": {
        "fontStyle": "bold"
      }
    },
    {
      "name": "Italic",
      "scope": [
        "markup.italic"
      ],
      "settings": {
        "fontStyle": "italic"
      }
    },
    {
      "name": "Strikethrough",
      "scope": [
        "markup.strikethrough"
      ],
      "settings": {
        "fontStyle": "strikethrough"
      }
    },
    {
      "name": "Links",
      "scope": [
        "markup.underline.link",
        "string.other.link",
        "constant.other.reference.link"
      ],
      "settings": {
        "foreground": "{{ accent }}",
        "fontStyle": "underline"
      }
    },
    {
      "name": "Quotes",
      "scope": [
        "markup.quote"
      ],
      "settings": {
        "foreground": "{{ muted }}",
        "fontStyle": "italic"
      }
    },
    {
      "name": "Lists",
      "scope": [
        "markup.list punctuation.definition.list.begin",
        "beginning.punctuation.definition.list"
      ],
      "settings": {
        "foreground": "{{ orange }}"
      }
    },
    {
      "name": "Inserted",
      "scope": [
        "markup.inserted",
        "meta.diff.header.to-file",
        "punctuation.definition.inserted"
      ],
      "settings": {
        "foreground": "{{ green }}"
      }
    },
    {
      "name": "Deleted",
      "scope": [
        "markup.deleted",
        "meta.diff.header.from-file",
        "punctuation.definition.deleted"
      ],
      "settings": {
        "foreground": "{{ red }}"
      }
    },
    {
      "name": "Changed",
      "scope": [
        "markup.changed",
        "punctuation.definition.changed"
      ],
      "settings": {
        "foreground": "{{ blue }}"
      }
    },
    {
      "name": "Diff ranges",
      "scope": [
        "meta.diff.range",
        "meta.diff.header"
      ],
      "settings": {
        "foreground": "{{ magenta }}"
      }
    },
    {
      "name": "JSON keys",
      "scope": [
        "support.type.property-name.json",
        "meta.mapping.key string.quoted"
      ],
      "settings": {
        "foreground": "{{ cyan }}"
      }
    }
  ],
  "semanticTokenColors": {
    "keyword": "{{ magenta }}",
    "function": "{{ blue }}",
    "method": "{{ blue }}",
    "macro": "{{ orange }}",
    "decorator": "{{ orange }}",
    "class": "{{ yellow }}",
    "struct": "{{ yellow }}",
    "interface": "{{ yellow }}",
    "enum": "{{ yellow }}",
    "type": "{{ yellow }}",
    "typeParameter": "{{ yellow }}",
    "namespace": "{{ yellow }}",
    "enumMember": "{{ orange }}",
    "number": "{{ orange }}",
    "boolean": "{{ orange }}",
    "variable.readonly": "{{ orange }}",
    "variable.defaultLibrary": "{{ orange }}",
    "string": "{{ green }}",
    "regexp": "{{ cyan }}",
    "operator": "{{ cyan }}",
    "property": "{{ cyan }}",
    "variable": "{{ foreground }}",
    "selfKeyword": {
      "foreground": "{{ red }}",
      "fontStyle": "italic"
    },
    "parameter": {
      "foreground": "{{ light_foreground }}",
      "fontStyle": "italic"
    },
    "comment": {
      "foreground": "{{ muted }}",
      "fontStyle": "italic"
    },
    "*.deprecated": {
      "fontStyle": "strikethrough"
    }
  }
}
