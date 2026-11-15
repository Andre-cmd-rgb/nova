import QtQuick
import Quickshell
import "plugins/image-picker/ImagePickerModel.js" as Model

// The image picker's rules: names and captions, the rows read, what a
// filter keeps and where, and an image's place. The answers are those of the
// rules as they were before their rewrite.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // JSON leaves out what is undefined, and so does the test's answer.
  function same(one, other) {
    return JSON.stringify(one === undefined ? null : one) === JSON.stringify(other)
  }

  function rows() {
    return ["/w/mountain-lake.png", "/w/city.jpg\t/t/city.jpg", "", "\t/t/orphan.jpg", "/x/mountain-lake.png", "/w/lake_at_dawn.png", "/w/forest.png", "/w/.hidden", "/w/dot.", "/w/no-extension", "/w/ünïcode_bild.webp\t", "relative.png\t/t/r.png\textra", "/w/CAPS--and__more.JPG", "/w/city.jpg"].join("\n")
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same(["/w/tokyo-night.png", "/w/tokyo-night.v2.svg", "/w/.hidden", "/w/dot.", "plain", "/dir.d/file", "", null, undefined, "/w/a.b.c.d", "/trailing/"].map(p => Model.nameOf(p)), ["tokyo-night","tokyo-night.v2","","dot.","plain","file","","","","a.b.c",""]), "names")
    check(same(["/w/lake_at_dawn.png", "/w/tokyo-night.v2.svg", "/w/CAPS--and__more.JPG", "/w/ünïcode_bild.webp", "/w/3d-art_x.png", "", null, "/w/a-b_c d.png"].map(p => Model.captionOf(p)), ["Lake At Dawn","Tokyo Night.V2","CAPS And More","üNïCode Bild","3d Art X","","","A B C D"]), "captions")
    check(same(Model.parse(rows()), [{"path":"/w/mountain-lake.png","thumbnail":"/w/mountain-lake.png","caption":"Mountain Lake","name":"mountain-lake","words":"mountain lake"},{"path":"/w/city.jpg","thumbnail":"/t/city.jpg","caption":"City","name":"city","words":"city"},{"path":"/w/lake_at_dawn.png","thumbnail":"/w/lake_at_dawn.png","caption":"Lake At Dawn","name":"lake_at_dawn","words":"lake at dawn"},{"path":"/w/forest.png","thumbnail":"/w/forest.png","caption":"Forest","name":"forest","words":"forest"},{"path":"/w/.hidden","thumbnail":"/w/.hidden","caption":"","name":"","words":""},{"path":"/w/dot.","thumbnail":"/w/dot.","caption":"Dot.","name":"dot.","words":"dot."},{"path":"/w/no-extension","thumbnail":"/w/no-extension","caption":"No Extension","name":"no-extension","words":"no extension"},{"path":"/w/ünïcode_bild.webp","thumbnail":"/w/ünïcode_bild.webp","caption":"üNïCode Bild","name":"ünïcode_bild","words":"ünïcode bild"},{"path":"relative.png","thumbnail":"/t/r.png","caption":"Relative","name":"relative","words":"relative"},{"path":"/w/CAPS--and__more.JPG","thumbnail":"/w/CAPS--and__more.JPG","caption":"CAPS And More","name":"caps--and__more","words":"caps and more"}]), "the rows read")
    check(same([Model.parse(""), Model.parse(null), Model.parse(undefined), Model.parse("\n\n"), Model.parse("/a.png\r\n/b.png")], [[],[],[],[],[{"path":"/a.png\r","thumbnail":"/a.png\r","caption":"A","name":"a","words":"a"},{"path":"/b.png","thumbnail":"/b.png","caption":"B","name":"b","words":"b"}]]), "and none")
    check(same(["", null, "lake", "LAKE AT", "e_a", "and", "png", " ", "zzz", "ün"].map(f => Model.parse(rows()).map(i => Model.keeps(i, f))), [[true,true,true,true,true,true,true,true,true,true],[true,true,true,true,true,true,true,true,true,true],[true,false,true,false,false,false,false,false,false,false],[false,false,true,false,false,false,false,false,false,false],[false,false,true,false,false,false,false,false,false,false],[false,false,false,false,false,false,false,false,false,true],[false,false,false,false,false,false,false,false,false,false],[true,false,true,false,false,false,true,true,false,true],[false,false,false,false,false,false,false,false,false,false],[false,false,false,false,false,false,false,true,false,false]]), "what a filter keeps")
    check(same(["", "lake", "city", "zzz", "w"].map(f => Model.positions(Model.parse(rows()), f)), [[0,1,2,3,4,5,6,7,8,9],[0,-1,1,-1,-1,-1,-1,-1,-1,-1],[-1,0,-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,0,-1,-1,-1,-1,-1,-1,-1]]), "where")
    check(same(["", "lake", "for", "zzz", "more"].map(f => Model.firstKept(Model.parse(rows()), f)).concat([Model.firstKept([], "")]), [0,0,3,-1,9,-1]), "the first kept")
    check(same(["/w/forest.png", "/w/none.png", "/w/city.jpg", "", null].map(p => Model.indexOf(Model.parse(rows()), p)).concat([Model.indexOf([], "/a")]), [3,0,1,0,0,0]), "an image's place")

    console.log("DONE")
    Qt.quit()
  }
}
