{
  "name": "Nova",
  "$schema": "vscode://schemas/color-theme",
  "type": "{{ mode }}",
  "semanticHighlighting": true,
  "colors": {
    "foreground": "{{ foreground }}",
    "disabledForeground": "{{ dark_foreground }}",
    "descriptionForeground": "{{ muted }}",
    "errorForeground": "{{ red }}",
    "icon.foreground": "{{ light_foreground }}",
    "focusBorder": "{{ accent }}99",
    "contrastBorder": "#00000000",
    "widget.shadow": "#00000040",
    "widget.border": "{{ mix background foreground 12% }}",
    "sash.hoverBorder": "{{ accent }}",
    "selection.background": "{{ selection_background }}",
    "textLink.foreground": "{{ accent }}",
    "textLink.activeForeground": "{{ bright_blue }}",
    "textPreformat.foreground": "{{ cyan }}",
    "textBlockQuote.background": "{{ dark_background }}",
    "textBlockQuote.border": "{{ accent }}",
    "textCodeBlock.background": "{{ dark_background }}",
    "textSeparator.foreground": "{{ mix background foreground 12% }}",
    "scrollbar.shadow": "#00000000",
    "scrollbarSlider.background": "{{ muted }}33",
    "scrollbarSlider.hoverBackground": "{{ muted }}55",
    "scrollbarSlider.activeBackground": "{{ muted }}77",
    "progressBar.background": "{{ accent }}",
    "badge.background": "{{ accent }}",
    "badge.foreground": "{{ background }}",
    "titleBar.activeBackground": "{{ dark_background }}",
    "titleBar.activeForeground": "{{ foreground }}",
    "titleBar.inactiveBackground": "{{ dark_background }}",
    "titleBar.inactiveForeground": "{{ muted }}",
    "titleBar.border": "{{ mix background foreground 12% }}",
    "commandCenter.background": "{{ background }}",
    "commandCenter.foreground": "{{ light_foreground }}",
    "commandCenter.border": "{{ mix background foreground 12% }}",
    "commandCenter.activeBackground": "{{ mix background foreground 6% }}",
    "commandCenter.inactiveForeground": "{{ muted }}",
    "menu.background": "{{ background }}",
    "menu.foreground": "{{ foreground }}",
    "menu.border": "{{ mix background foreground 12% }}",
    "menu.selectionBackground": "{{ mix background accent 18% }}",
    "menu.selectionForeground": "{{ bright_foreground }}",
    "menu.separatorBackground": "{{ mix background foreground 12% }}",
    "menubar.selectionBackground": "{{ mix background foreground 6% }}",
    "menubar.selectionForeground": "{{ bright_foreground }}",
    "activityBar.background": "{{ dark_background }}",
    "activityBar.foreground": "{{ foreground }}",
    "activityBar.inactiveForeground": "{{ muted }}",
    "activityBar.activeBorder": "{{ accent }}",
    "activityBar.border": "{{ mix background foreground 12% }}",
    "activityBarBadge.background": "{{ accent }}",
    "activityBarBadge.foreground": "{{ background }}",
    "activityBarTop.foreground": "{{ foreground }}",
    "activityBarTop.inactiveForeground": "{{ muted }}",
    "activityBarTop.activeBorder": "{{ accent }}",
    "sideBar.background": "{{ dark_background }}",
    "sideBar.foreground": "{{ light_foreground }}",
    "sideBar.border": "{{ mix background foreground 12% }}",
    "sideBarTitle.foreground": "{{ foreground }}",
    "sideBarSectionHeader.background": "{{ dark_background }}",
    "sideBarSectionHeader.foreground": "{{ foreground }}",
    "sideBarSectionHeader.border": "{{ mix background foreground 12% }}",
    "sideBarStickyScroll.background": "{{ dark_background }}",
    "list.activeSelectionBackground": "{{ mix background accent 18% }}",
    "list.activeSelectionForeground": "{{ bright_foreground }}",
    "list.inactiveSelectionBackground": "{{ mix background foreground 6% }}",
    "list.inactiveSelectionForeground": "{{ foreground }}",
    "list.hoverBackground": "{{ mix background foreground 6% }}",
    "list.hoverForeground": "{{ foreground }}",
    "list.focusOutline": "{{ accent }}66",
    "list.focusBackground": "{{ mix background accent 18% }}",
    "list.highlightForeground": "{{ accent }}",
    "list.focusHighlightForeground": "{{ accent }}",
    "list.dropBackground": "{{ mix background accent 18% }}",
    "list.errorForeground": "{{ red }}",
    "list.warningForeground": "{{ yellow }}",
    "list.invalidItemForeground": "{{ red }}",
    "list.deemphasizedForeground": "{{ muted }}",
    "tree.indentGuidesStroke": "{{ mix background foreground 12% }}",
    "tree.inactiveIndentGuidesStroke": "{{ mix background foreground 6% }}",
    "listFilterWidget.background": "{{ background }}",
    "listFilterWidget.outline": "{{ accent }}",
    "listFilterWidget.noMatchesOutline": "{{ red }}",
    "input.background": "{{ dark_background }}",
    "input.foreground": "{{ foreground }}",
    "input.border": "{{ mix background foreground 12% }}",
    "input.placeholderForeground": "{{ muted }}",
    "inputOption.activeBackground": "{{ accent }}33",
    "inputOption.activeBorder": "{{ accent }}",
    "inputOption.activeForeground": "{{ bright_foreground }}",
    "inputValidation.errorBackground": "{{ background }}",
    "inputValidation.errorBorder": "{{ red }}",
    "inputValidation.warningBackground": "{{ background }}",
    "inputValidation.warningBorder": "{{ yellow }}",
    "inputValidation.infoBackground": "{{ background }}",
    "inputValidation.infoBorder": "{{ blue }}",
    "dropdown.background": "{{ dark_background }}",
    "dropdown.foreground": "{{ foreground }}",
    "dropdown.border": "{{ mix background foreground 12% }}",
    "dropdown.listBackground": "{{ background }}",
    "checkbox.background": "{{ dark_background }}",
    "checkbox.foreground": "{{ foreground }}",
    "checkbox.border": "{{ mix background foreground 12% }}",
    "checkbox.selectBackground": "{{ dark_background }}",
    "checkbox.selectBorder": "{{ accent }}",
    "button.background": "{{ accent }}",
    "button.foreground": "{{ background }}",
    "button.hoverBackground": "{{ mix accent foreground 15% }}",
    "button.border": "#00000000",
    "button.separator": "{{ background }}66",
    "button.secondaryBackground": "{{ lighter_background }}",
    "button.secondaryForeground": "{{ foreground }}",
    "button.secondaryHoverBackground": "{{ mix lighter_background foreground 10% }}",
    "keybindingLabel.background": "{{ lighter_background }}",
    "keybindingLabel.foreground": "{{ foreground }}",
    "keybindingLabel.border": "{{ mix background foreground 12% }}",
    "keybindingLabel.bottomBorder": "{{ mix background foreground 12% }}",
    "extensionButton.prominentBackground": "{{ accent }}",
    "extensionButton.prominentForeground": "{{ background }}",
    "extensionButton.prominentHoverBackground": "{{ mix accent foreground 15% }}",
    "extensionBadge.remoteBackground": "{{ accent }}",
    "extensionBadge.remoteForeground": "{{ background }}",
    "extensionIcon.starForeground": "{{ yellow }}",
    "extensionIcon.verifiedForeground": "{{ accent }}",
    "extensionIcon.preReleaseForeground": "{{ orange }}",
    "editor.background": "{{ background }}",
    "editor.foreground": "{{ foreground }}",
    "editorLineNumber.foreground": "{{ dark_foreground }}",
    "editorLineNumber.activeForeground": "{{ light_foreground }}",
    "editorCursor.foreground": "{{ cursor }}",
    "editor.selectionBackground": "{{ selection_background }}",
    "editor.inactiveSelectionBackground": "{{ selection_background }}88",
    "editor.selectionHighlightBackground": "{{ selection_background }}66",
    "editor.wordHighlightBackground": "{{ selection_background }}55",
    "editor.wordHighlightStrongBackground": "{{ selection_background }}88",
    "editor.findMatchBackground": "{{ orange }}55",
    "editor.findMatchBorder": "{{ orange }}",
    "editor.findMatchHighlightBackground": "{{ orange }}2a",
    "editor.findRangeHighlightBackground": "{{ accent }}14",
    "editor.lineHighlightBackground": "{{ mix background foreground 4% }}",
    "editor.lineHighlightBorder": "#00000000",
    "editor.rangeHighlightBackground": "{{ accent }}14",
    "editor.hoverHighlightBackground": "{{ accent }}22",
    "editor.linkedEditingBackground": "{{ accent }}22",
    "editorLink.activeForeground": "{{ accent }}",
    "editorWhitespace.foreground": "{{ mix background foreground 18% }}",
    "editorIndentGuide.background1": "{{ mix background foreground 8% }}",
    "editorIndentGuide.activeBackground1": "{{ mix background foreground 22% }}",
    "editorRuler.foreground": "{{ mix background foreground 12% }}",
    "editorCodeLens.foreground": "{{ muted }}",
    "editorBracketMatch.background": "{{ accent }}22",
    "editorBracketMatch.border": "{{ accent }}88",
    "editorBracketHighlight.foreground1": "{{ yellow }}",
    "editorBracketHighlight.foreground2": "{{ magenta }}",
    "editorBracketHighlight.foreground3": "{{ blue }}",
    "editorBracketHighlight.foreground4": "{{ cyan }}",
    "editorBracketHighlight.foreground5": "{{ green }}",
    "editorBracketHighlight.foreground6": "{{ orange }}",
    "editorBracketHighlight.unexpectedBracket.foreground": "{{ red }}",
    "editorUnnecessaryCode.opacity": "#000000aa",
    "editorInlayHint.background": "{{ lighter_background }}aa",
    "editorInlayHint.foreground": "{{ muted }}",
    "editorGhostText.foreground": "{{ muted }}",
    "editorError.foreground": "{{ red }}",
    "editorWarning.foreground": "{{ yellow }}",
    "editorInfo.foreground": "{{ blue }}",
    "editorHint.foreground": "{{ green }}",
    "problemsErrorIcon.foreground": "{{ red }}",
    "problemsWarningIcon.foreground": "{{ yellow }}",
    "problemsInfoIcon.foreground": "{{ blue }}",
    "editorLightBulb.foreground": "{{ yellow }}",
    "editorLightBulbAutoFix.foreground": "{{ blue }}",
    "editorGutter.background": "{{ background }}",
    "editorGutter.addedBackground": "{{ green }}",
    "editorGutter.modifiedBackground": "{{ blue }}",
    "editorGutter.deletedBackground": "{{ red }}",
    "editorGutter.foldingControlForeground": "{{ muted }}",
    "editorOverviewRuler.border": "#00000000",
    "editorOverviewRuler.errorForeground": "{{ red }}",
    "editorOverviewRuler.warningForeground": "{{ yellow }}",
    "editorOverviewRuler.infoForeground": "{{ blue }}",
    "editorOverviewRuler.addedForeground": "{{ green }}99",
    "editorOverviewRuler.modifiedForeground": "{{ blue }}99",
    "editorOverviewRuler.deletedForeground": "{{ red }}99",
    "editorOverviewRuler.findMatchForeground": "{{ orange }}99",
    "editorOverviewRuler.selectionHighlightForeground": "{{ accent }}66",
    "editorStickyScroll.background": "{{ background }}",
    "editorStickyScroll.shadow": "#00000040",
    "editorStickyScrollHover.background": "{{ mix background foreground 6% }}",
    "editorWidget.background": "{{ dark_background }}",
    "editorWidget.foreground": "{{ foreground }}",
    "editorWidget.border": "{{ mix background foreground 12% }}",
    "editorWidget.resizeBorder": "{{ accent }}",
    "editorSuggestWidget.background": "{{ dark_background }}",
    "editorSuggestWidget.foreground": "{{ foreground }}",
    "editorSuggestWidget.border": "{{ mix background foreground 12% }}",
    "editorSuggestWidget.selectedBackground": "{{ mix background accent 18% }}",
    "editorSuggestWidget.selectedForeground": "{{ bright_foreground }}",
    "editorSuggestWidget.highlightForeground": "{{ accent }}",
    "editorSuggestWidget.focusHighlightForeground": "{{ accent }}",
    "editorHoverWidget.background": "{{ dark_background }}",
    "editorHoverWidget.foreground": "{{ foreground }}",
    "editorHoverWidget.border": "{{ mix background foreground 12% }}",
    "editorHoverWidget.statusBarBackground": "{{ dark_background }}",
    "editorMarkerNavigation.background": "{{ dark_background }}",
    "editorMarkerNavigationError.background": "{{ red }}",
    "editorMarkerNavigationWarning.background": "{{ yellow }}",
    "editorMarkerNavigationInfo.background": "{{ blue }}",
    "peekView.border": "{{ accent }}",
    "peekViewTitle.background": "{{ dark_background }}",
    "peekViewTitleLabel.foreground": "{{ foreground }}",
    "peekViewTitleDescription.foreground": "{{ muted }}",
    "peekViewEditor.background": "{{ dark_background }}",
    "peekViewEditor.matchHighlightBackground": "{{ orange }}44",
    "peekViewEditorGutter.background": "{{ dark_background }}",
    "peekViewResult.background": "{{ dark_background }}",
    "peekViewResult.fileForeground": "{{ foreground }}",
    "peekViewResult.lineForeground": "{{ light_foreground }}",
    "peekViewResult.matchHighlightBackground": "{{ orange }}44",
    "peekViewResult.selectionBackground": "{{ mix background accent 18% }}",
    "peekViewResult.selectionForeground": "{{ bright_foreground }}",
    "debugExceptionWidget.background": "{{ dark_background }}",
    "debugExceptionWidget.border": "{{ red }}",
    "editorGroup.border": "{{ mix background foreground 12% }}",
    "editorGroup.dropBackground": "{{ accent }}22",
    "editorGroupHeader.tabsBackground": "{{ dark_background }}",
    "editorGroupHeader.tabsBorder": "{{ mix background foreground 12% }}",
    "editorGroupHeader.noTabsBackground": "{{ background }}",
    "editorGroupHeader.border": "{{ mix background foreground 12% }}",
    "tab.activeBackground": "{{ background }}",
    "tab.activeForeground": "{{ bright_foreground }}",
    "tab.activeBorderTop": "{{ accent }}",
    "tab.activeBorder": "{{ background }}",
    "tab.inactiveBackground": "{{ dark_background }}",
    "tab.inactiveForeground": "{{ muted }}",
    "tab.hoverBackground": "{{ mix background foreground 6% }}",
    "tab.hoverForeground": "{{ foreground }}",
    "tab.border": "{{ mix background foreground 12% }}",
    "tab.unfocusedActiveBackground": "{{ background }}",
    "tab.unfocusedActiveForeground": "{{ light_foreground }}",
    "tab.unfocusedActiveBorderTop": "{{ mix background foreground 12% }}",
    "tab.unfocusedInactiveBackground": "{{ dark_background }}",
    "tab.unfocusedInactiveForeground": "{{ muted }}",
    "tab.lastPinnedBorder": "{{ mix background foreground 12% }}",
    "tab.dragAndDropBorder": "{{ accent }}",
    "breadcrumb.background": "{{ background }}",
    "breadcrumb.foreground": "{{ muted }}",
    "breadcrumb.focusForeground": "{{ foreground }}",
    "breadcrumb.activeSelectionForeground": "{{ bright_foreground }}",
    "breadcrumbPicker.background": "{{ dark_background }}",
    "panel.background": "{{ background }}",
    "panel.border": "{{ mix background foreground 12% }}",
    "panelTitle.activeForeground": "{{ foreground }}",
    "panelTitle.activeBorder": "{{ accent }}",
    "panelTitle.inactiveForeground": "{{ muted }}",
    "panelInput.border": "{{ mix background foreground 12% }}",
    "panelSection.border": "{{ mix background foreground 12% }}",
    "panelSectionHeader.background": "{{ dark_background }}",
    "statusBar.background": "{{ dark_background }}",
    "statusBar.foreground": "{{ light_foreground }}",
    "statusBar.border": "{{ mix background foreground 12% }}",
    "statusBar.noFolderBackground": "{{ dark_background }}",
    "statusBar.noFolderForeground": "{{ light_foreground }}",
    "statusBar.debuggingBackground": "{{ orange }}",
    "statusBar.debuggingForeground": "{{ background }}",
    "statusBar.focusBorder": "{{ accent }}",
    "statusBarItem.hoverBackground": "{{ mix background foreground 6% }}",
    "statusBarItem.activeBackground": "{{ mix background accent 18% }}",
    "statusBarItem.remoteBackground": "{{ accent }}",
    "statusBarItem.remoteForeground": "{{ background }}",
    "statusBarItem.prominentBackground": "{{ lighter_background }}",
    "statusBarItem.prominentForeground": "{{ foreground }}",
    "statusBarItem.errorBackground": "{{ red }}",
    "statusBarItem.errorForeground": "{{ background }}",
    "statusBarItem.warningBackground": "{{ yellow }}",
    "statusBarItem.warningForeground": "{{ background }}",
    "statusBarItem.focusBorder": "{{ accent }}",
    "quickInput.background": "{{ dark_background }}",
    "quickInput.foreground": "{{ foreground }}",
    "quickInputTitle.background": "{{ dark_background }}",
    "quickInputList.focusBackground": "{{ mix background accent 18% }}",
    "quickInputList.focusForeground": "{{ bright_foreground }}",
    "pickerGroup.foreground": "{{ accent }}",
    "pickerGroup.border": "{{ mix background foreground 12% }}",
    "notifications.background": "{{ dark_background }}",
    "notifications.foreground": "{{ foreground }}",
    "notifications.border": "{{ mix background foreground 12% }}",
    "notificationCenter.border": "{{ mix background foreground 12% }}",
    "notificationCenterHeader.background": "{{ dark_background }}",
    "notificationCenterHeader.foreground": "{{ foreground }}",
    "notificationToast.border": "{{ mix background foreground 12% }}",
    "notificationLink.foreground": "{{ accent }}",
    "notificationsErrorIcon.foreground": "{{ red }}",
    "notificationsWarningIcon.foreground": "{{ yellow }}",
    "notificationsInfoIcon.foreground": "{{ blue }}",
    "banner.background": "{{ lighter_background }}",
    "banner.foreground": "{{ foreground }}",
    "banner.iconForeground": "{{ accent }}",
    "settings.headerForeground": "{{ foreground }}",
    "settings.modifiedItemIndicator": "{{ accent }}",
    "settings.focusedRowBackground": "{{ mix background foreground 6% }}",
    "settings.rowHoverBackground": "{{ mix background foreground 6% }}",
    "settings.focusedRowBorder": "{{ accent }}66",
    "welcomePage.background": "{{ background }}",
    "welcomePage.tileBackground": "{{ dark_background }}",
    "welcomePage.tileHoverBackground": "{{ mix background foreground 6% }}",
    "welcomePage.tileBorder": "{{ mix background foreground 12% }}",
    "walkThrough.embeddedEditorBackground": "{{ dark_background }}",
    "terminal.background": "{{ background }}",
    "terminal.foreground": "{{ foreground }}",
    "terminal.border": "{{ mix background foreground 12% }}",
    "terminal.selectionBackground": "{{ selection_background }}",
    "terminalCursor.foreground": "{{ cursor }}",
    "terminalCursor.background": "{{ background }}",
    "terminal.findMatchBackground": "{{ orange }}55",
    "terminal.ansiBlack": "{{ color0 }}",
    "terminal.ansiRed": "{{ color1 }}",
    "terminal.ansiGreen": "{{ color2 }}",
    "terminal.ansiYellow": "{{ color3 }}",
    "terminal.ansiBlue": "{{ color4 }}",
    "terminal.ansiMagenta": "{{ color5 }}",
    "terminal.ansiCyan": "{{ color6 }}",
    "terminal.ansiWhite": "{{ color7 }}",
    "terminal.ansiBrightBlack": "{{ color8 }}",
    "terminal.ansiBrightRed": "{{ color9 }}",
    "terminal.ansiBrightGreen": "{{ color10 }}",
    "terminal.ansiBrightYellow": "{{ color11 }}",
    "terminal.ansiBrightBlue": "{{ color12 }}",
    "terminal.ansiBrightMagenta": "{{ color13 }}",
    "terminal.ansiBrightCyan": "{{ color14 }}",
    "terminal.ansiBrightWhite": "{{ color15 }}",
    "terminalCommandDecoration.defaultBackground": "{{ muted }}",
    "terminalCommandDecoration.successBackground": "{{ green }}",
    "terminalCommandDecoration.errorBackground": "{{ red }}",
    "gitDecoration.addedResourceForeground": "{{ green }}",
    "gitDecoration.modifiedResourceForeground": "{{ blue }}",
    "gitDecoration.deletedResourceForeground": "{{ red }}",
    "gitDecoration.renamedResourceForeground": "{{ cyan }}",
    "gitDecoration.untrackedResourceForeground": "{{ green }}",
    "gitDecoration.ignoredResourceForeground": "{{ dark_foreground }}",
    "gitDecoration.conflictingResourceForeground": "{{ orange }}",
    "gitDecoration.stageModifiedResourceForeground": "{{ blue }}",
    "gitDecoration.stageDeletedResourceForeground": "{{ red }}",
    "gitDecoration.submoduleResourceForeground": "{{ magenta }}",
    "diffEditor.insertedTextBackground": "{{ green }}26",
    "diffEditor.removedTextBackground": "{{ red }}26",
    "diffEditor.insertedLineBackground": "{{ green }}14",
    "diffEditor.removedLineBackground": "{{ red }}14",
    "diffEditor.diagonalFill": "{{ mix background foreground 12% }}",
    "diffEditor.border": "{{ mix background foreground 12% }}",
    "diffEditorGutter.insertedLineBackground": "{{ green }}26",
    "diffEditorGutter.removedLineBackground": "{{ red }}26",
    "merge.currentHeaderBackground": "{{ green }}55",
    "merge.currentContentBackground": "{{ green }}22",
    "merge.incomingHeaderBackground": "{{ blue }}55",
    "merge.incomingContentBackground": "{{ blue }}22",
    "merge.commonHeaderBackground": "{{ muted }}55",
    "merge.commonContentBackground": "{{ muted }}22",
    "minimap.background": "{{ background }}",
    "minimap.findMatchHighlight": "{{ orange }}aa",
    "minimap.selectionHighlight": "{{ accent }}66",
    "minimap.errorHighlight": "{{ red }}aa",
    "minimap.warningHighlight": "{{ yellow }}aa",
    "minimapGutter.addedBackground": "{{ green }}",
    "minimapGutter.modifiedBackground": "{{ blue }}",
    "minimapGutter.deletedBackground": "{{ red }}",
    "minimapSlider.background": "{{ muted }}22",
    "minimapSlider.hoverBackground": "{{ muted }}33",
    "minimapSlider.activeBackground": "{{ muted }}44",
    "debugToolBar.background": "{{ dark_background }}",
    "debugToolBar.border": "{{ mix background foreground 12% }}",
    "debugIcon.breakpointForeground": "{{ red }}",
    "debugIcon.startForeground": "{{ green }}",
    "debugIcon.stopForeground": "{{ red }}",
    "debugIcon.pauseForeground": "{{ yellow }}",
    "debugIcon.continueForeground": "{{ green }}",
    "debugIcon.restartForeground": "{{ green }}",
    "debugIcon.stepOverForeground": "{{ blue }}",
    "debugIcon.stepIntoForeground": "{{ blue }}",
    "debugIcon.stepOutForeground": "{{ blue }}",
    "debugConsole.infoForeground": "{{ blue }}",
    "debugConsole.warningForeground": "{{ yellow }}",
    "debugConsole.errorForeground": "{{ red }}",
    "debugConsole.sourceForeground": "{{ light_foreground }}",
    "testing.iconPassed": "{{ green }}",
    "testing.iconFailed": "{{ red }}",
    "testing.iconErrored": "{{ red }}",
    "testing.iconQueued": "{{ yellow }}",
    "testing.iconSkipped": "{{ muted }}",
    "testing.runAction": "{{ green }}",
    "charts.foreground": "{{ foreground }}",
    "charts.lines": "{{ mix background foreground 12% }}",
    "charts.red": "{{ red }}",
    "charts.blue": "{{ blue }}",
    "charts.yellow": "{{ yellow }}",
    "charts.orange": "{{ orange }}",
    "charts.green": "{{ green }}",
    "charts.purple": "{{ magenta }}",
    "notebook.cellBorderColor": "{{ mix background foreground 12% }}",
    "notebook.focusedCellBorder": "{{ accent }}88",
    "notebook.cellEditorBackground": "{{ dark_background }}",
    "notebook.selectedCellBackground": "{{ mix background foreground 6% }}",
    "notebook.cellHoverBackground": "{{ mix background foreground 6% }}",
    "notebook.outputContainerBackgroundColor": "{{ dark_background }}",
    "chat.requestBackground": "{{ dark_background }}",
    "chat.requestBorder": "{{ mix background foreground 12% }}",
    "chat.slashCommandBackground": "{{ lighter_background }}",
    "chat.slashCommandForeground": "{{ accent }}",
    "inlineChat.background": "{{ dark_background }}",
    "inlineChat.border": "{{ mix background foreground 12% }}",
    "inlineChatInput.background": "{{ background }}",
    "inlineChatInput.border": "{{ mix background foreground 12% }}",
    "inlineChatInput.focusBorder": "{{ accent }}",
    "inlineChatInput.placeholderForeground": "{{ muted }}",
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
    "symbolIcon.fileForeground": "{{ foreground }}",
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
    "symbolIcon.textForeground": "{{ foreground }}",
    "symbolIcon.typeParameterForeground": "{{ yellow }}",
    "symbolIcon.unitForeground": "{{ orange }}",
    "symbolIcon.variableForeground": "{{ foreground }}"
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
