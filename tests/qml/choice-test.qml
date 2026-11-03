import QtQuick
import Quickshell
import qs.Ui

// A dropdown's value is its owner's: a choice sends changed() and leaves the
// field showing what the owner holds, so a field bound to a setting shows a
// change it refused as refused, and follows the setting after a choice. In a
// dropdown and a button group alike, an option with no label shows its value.
ShellRoot {
  id: test

  property string taken: "a"
  property string refused: "a"
  property var sent: []

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  Item {
    Dropdown {
      id: taking
      options: ["a", { value: "b", label: "Bee" }, "c"]
      value: test.taken
      onChanged: function (value) { test.taken = value }
    }

    Dropdown {
      id: refusing
      options: ["a", "b", "c"]
      value: test.refused
      onChanged: function (value) { test.sent = test.sent.concat([value]) }
    }

    Dropdown {
      id: unlabelled
      options: [{ value: "left-of" }, { value: "above", label: "Above" }, "below"]
      value: "left-of"
    }

    ButtonGroup {
      id: buttons
      options: [{ value: "left-of" }, { value: "above", label: "Above" }, "below"]
      value: "left-of"
    }
  }

  Component.onCompleted: Qt.callLater(function () {
    taking.choose(1)
    check(test.taken === "b" && taking.value === "b", "a choice the owner takes shows as taken")
    check(taking.currentLabel() === "Bee", "the field names the chosen option by its label")
    test.taken = "c"
    check(taking.value === "c", "the field follows its setting after a choice")

    refusing.choose(2)
    check(JSON.stringify(test.sent) === '["c"]', "a choice sends its value once")
    check(refusing.value === "a", "a choice the owner refuses leaves the field on the setting")
    test.refused = "b"
    check(refusing.value === "b", "the field follows its setting after a refused choice")

    refusing.choose(-1)
    refusing.choose(3)
    check(test.sent.length === 1, "an index outside the list sends nothing")

    var labels = [0, 1, 2].map(function (i) { return unlabelled.optionLabel(unlabelled.options[i]) })
    check(JSON.stringify(labels) === '["left-of","Above","below"]' && unlabelled.currentLabel() === "left-of", "a dropdown's option with no label shows its value")
    labels = [0, 1, 2].map(function (i) { return buttons.optionLabel(buttons.options[i]) })
    check(JSON.stringify(labels) === '["left-of","Above","below"]', "a button group's option with no label shows its value")
    console.log("DONE")
    Qt.quit()
  })
}
