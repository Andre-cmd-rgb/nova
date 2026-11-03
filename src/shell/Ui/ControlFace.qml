import QtQuick
import qs.Commons
import qs.Commons as Commons

// A control's face, painted in one of the theme's [controls] states. The
// control says which state its fill and its border are in, and this is the
// one place that turns a state into colours:
//   <fillState>  "pressed", "focus", "hover-cursor", "selected" or "normal":
//                that state's colour at its fill alpha; "" for <restColor>
//   <edgeState>  "focus", "hover-cursor", "selected" or "normal": that
//                state's border from Border.controlSpec; "" for none
// The colours are worked out from <tint> and <tintAccent>, as Style's and
// Border's state functions take a foreground and an accent. A <fade> above
// zero eases a change of fill over that many milliseconds.
BorderSurface {
  id: face

  property string fillState: ""
  property string edgeState: ""
  property color restColor: "transparent"
  property color tint: Commons.Color.foreground
  property color tintAccent: Commons.Color.accent
  property int fade: 0

  function fillOf(state) {
    switch (state) {
    case "pressed": return Style.pressedFillFor(tint, tintAccent)
    case "focus": return Style.focusFillFor(tint, tintAccent)
    case "hover-cursor": return Style.hoverFillFor(tint, tintAccent)
    case "selected": return Style.selectedFillFor(tint, tintAccent)
    case "normal": return Style.normalFillFor(tint, tintAccent)
    }
    return restColor
  }

  function edgeOf(state) {
    return state === "" ? Border.none() : Border.controlSpec(state, tint, tintAccent)
  }

  color: fillOf(fillState)
  borderSpec: edgeOf(edgeState)

  Behavior on color {
    enabled: face.fade > 0
    ColorAnimation { duration: face.fade }
  }
}
