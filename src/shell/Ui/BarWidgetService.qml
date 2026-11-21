import QtQuick

// What a service behind a bar widget is built on (BarWidget's <shared>): the
// copies of the widget that hold it, one on each screen's bar, and whether
// one does. The service works while <wanted> and rests while not, and reads
// its settings from the first copy's entry: each copy has the same one.
Item {
  // Set by the shell.
  property var shell: null

  property var holders: []
  readonly property bool wanted: holders.length > 0
  readonly property var first: holders.length > 0 ? holders[0] : null
  // Whether one of the copies has its panel open.
  readonly property bool panelOpen: holders.some(holder => holder.opened === true)

  // The widget's entry's <name>, or <fallback>.
  function setting(name, fallback) {
    return first ? first.setting(name, fallback) : fallback
  }

  function hold(holder) {
    if (holders.indexOf(holder) < 0) holders = holders.concat([holder])
  }

  function release(holder) {
    holders = holders.filter(one => one !== holder)
  }
}
