import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Set hours, every day: from one time of day to another, each picked on the
// half hour, as "22:00". A time set otherwise (with a command) is offered
// too, in its place. A pick sends its own end alone, "from" or "to", and
// the command takes the other from where it is kept: Settings reads its
// state back only once every change has run, so a second pick before then
// would otherwise send the first one's end as it was.
Line {
  id: hours

  property string from: "22:00"
  property string to: "07:00"
  signal picked(string end, string time)

  function times(current) {
    var list = []
    for (var minutes = 0; minutes < 24 * 60; minutes += 30)
      list.push(String(Math.floor(minutes / 60)).padStart(2, "0") + ":" + String(minutes % 60).padStart(2, "0"))
    if (list.indexOf(current) < 0) list.push(current)
    return list.sort().map(function (time) { return { value: time, label: time } })
  }

  label: "Hours"

  Row {
    spacing: Style.space(8)
    Dropdown {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      options: hours.times(hours.from)
      value: hours.from
      onChanged: function (value) { if (value !== hours.from) hours.picked("from", value) }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "to"
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Dropdown {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      options: hours.times(hours.to)
      value: hours.to
      onChanged: function (value) { if (value !== hours.to) hours.picked("to", value) }
    }
  }
}
