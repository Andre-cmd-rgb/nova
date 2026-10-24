import QtQuick
import Quickshell
import "plugins/image-picker/ImagePickerModel.js" as ImagePickerModel

// The image picker's slices: each image's place among those the filter
// keeps, worked out in one pass for all of them.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var images = ImagePickerModel.loadRows(["/w/mountain-lake.png", "/w/city.jpg", "/w/lake_at_dawn.png", "/w/forest.png"].join("\n"))
    check(ImagePickerModel.filteredPositions(images, "").join(" ") === "0 1 2 3", "no filter: every image in its place")
    check(ImagePickerModel.filteredPositions(images, "lake").join(" ") === "0 -1 1 -1",
      "a filter: the kept in order, the dropped at -1")

    var many = []
    for (var i = 0; i < 4000; i++) many.push("/w/wallpaper-" + i + (i % 2 ? "-dark" : "") + ".png")
    var started = Date.now()
    var positions = ImagePickerModel.filteredPositions(ImagePickerModel.loadRows(many.join("\n")), "dark")
    check(positions[3999] === 1999 && positions[3998] === -1 && Date.now() - started < 1000,
      "4000 images filtered in one pass (" + (Date.now() - started) + " ms)")
    console.log("DONE")
    Qt.quit()
  }
}
