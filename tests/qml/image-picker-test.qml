import QtQuick
import Quickshell
import "plugins/image-picker/ImagePickerModel.js" as Model

// The image picker's list: the rows a request brings, the captions, which
// images a filter keeps, and each one's place among them, worked out in one
// pass for all of them.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function paths(images) {
    return images.map(function (image) { return image.path + (image.thumbnail !== image.path ? ">" + image.thumbnail : "") }).join(" ")
  }

  function run() {
    var rows = ["/w/mountain-lake.png", "/w/city.jpg\t/t/city.jpg", "", "\t/t/orphan.jpg", "/x/mountain-lake.png", "/w/lake_at_dawn.png", "/w/forest.png"]
    var images = Model.parse(rows.join("\n"))
    check(paths(images) === "/w/mountain-lake.png /w/city.jpg>/t/city.jpg /w/lake_at_dawn.png /w/forest.png",
      "rows: a path and its thumbnail; blank rows, rows with no path and a file name seen before are left out")
    check(Model.parse("").length === 0 && Model.parse(undefined).length === 0, "no rows, no images")
    check(Model.captionOf("/w/lake_at_dawn.png") === "Lake At Dawn" && Model.captionOf("/w/tokyo-night.v2.svg") === "Tokyo Night.V2"
      && Model.nameOf("/w/tokyo-night.v2.svg") === "tokyo-night.v2", "a caption from the file name")

    check(Model.positions(images, "").join(" ") === "0 1 2 3", "no filter: every image in its place")
    check(Model.positions(images, "lake").join(" ") === "0 -1 1 -1", "a filter: the kept in order, the dropped at -1")
    check(Model.positions(images, "Lake At").join(" ") === "-1 -1 0 -1" && Model.positions(images, "e_a").join(" ") === "-1 -1 0 -1",
      "a filter matches the caption or the name, whatever the case")
    check(Model.firstKept(images, "for") === 3 && Model.firstKept(images, "zzz") === -1, "the first image a filter keeps")
    check(Model.indexOf(images, "/w/forest.png") === 3 && Model.indexOf(images, "/w/none.png") === 0, "an image's place, the first's for one not there")

    var many = []
    for (var i = 0; i < 4000; i++) many.push("/w/wallpaper-" + i + (i % 2 ? "-dark" : "") + ".png")
    var started = Date.now()
    var positions = Model.positions(Model.parse(many.join("\n")), "dark")
    check(positions[3999] === 1999 && positions[3998] === -1 && Date.now() - started < 1000,
      "4000 images filtered in one pass (" + (Date.now() - started) + " ms)")
    console.log("DONE")
    Qt.quit()
  }
}
