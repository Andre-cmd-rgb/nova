import QtQuick
import qs.Commons
import qs.Commons as Commons

// How the menu looks: the [menu] colours of shell.toml, each with its alpha,
// and its measures, in one place for the window and its rows.
QtObject {
  readonly property string font: Style.font.menuFamily

  readonly property color paper: Commons.Color.menu.background
  readonly property color ink: Commons.Color.menu.text
  readonly property color shade: Commons.Color.menu.scrim
  readonly property color cursorPaper: Commons.Color.menu.selectedBackground
  readonly property color cursorInk: Commons.Color.menu.selectedText
  readonly property var frame: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
  readonly property var cursorFrame: Border.surfaceSpec("menu", "selected-border", Commons.Color.menu.selectedBorder, 0)

  readonly property int radius: Style.cornerRadius
  // Around the card's content, and between its header and its rows.
  readonly property int padding: Style.spacing.panelPadding
  readonly property int headerGap: Style.spacing.md
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)

  // A row, and one with a line under its label; the gap between rows, and
  // the divider above a search's deeper rows.
  readonly property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  readonly property int tallRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property int rowGap: Style.spacing.xs
  readonly property int dividerHeight: Style.space(17)
  // How much of the first row below the fold shows: enough to read as a row
  // cut short rather than a border.
  readonly property int peek: Math.round(rowHeight * 0.55)

  // Every row keeps room for the cursor's border at its sides, so that the
  // cursor moving shifts no text.
  readonly property real cursorLeft: Border.left(cursorFrame)
  readonly property real cursorRight: Border.right(cursorFrame)
  // In a row: the glyph's column, and the room before it, after it and
  // before a label with none; the › at the end.
  readonly property real glyphColumn: Style.space(36)
  readonly property real glyphInset: Style.space(8)
  readonly property real glyphGap: Style.space(6)
  readonly property real bareInset: Style.space(18)
  readonly property real chevronWidth: Style.space(14)
  readonly property real lineGap: Style.space(3)

  // The measures listHeight() reads.
  readonly property var rows: ({ row: rowHeight, tall: tallRowHeight, gap: rowGap, divider: dividerHeight, peek: peek })
}
