import QtQuick
import Quickshell
import "plugins/panels/weather/Model.js" as Model

// The weather panel's rules: the place kept and asked for, the searches'
// answers, the two services' weather now and days ahead, the units and the
// glyphs. The answers are those of the rules as they were before their
// rewrite.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // JSON leaves out what is undefined, and so does the test's answer.
  function same(one, other) {
    return JSON.stringify(one === undefined ? null : one) === JSON.stringify(other)
  }

  function wttr() {
    return {
      current_condition: [{ temp_C: "12", temp_F: "54", FeelsLikeC: "10", FeelsLikeF: "50", windspeedKmph: "15", windspeedMiles: "9", humidity: "80", weatherCode: "116" }],
      nearest_area: [{ areaName: [{ value: "Cork" }], country: [{ value: "Ireland" }], latitude: "51.900", longitude: "-8.470" }],
      weather: [
        { date: "2026-11-14", maxtempC: "13", mintempC: "8", maxtempF: "55", mintempF: "46", hourly: [{ time: "0", weatherCode: "113" }, { time: "1200", weatherCode: "296" }] },
        { date: "2026-11-15", maxtempC: "11", mintempC: "6", maxtempF: "52", mintempF: "43", hourly: [{ time: "900", weatherCode: "119" }, { time: "1500", weatherCode: "338" }] },
        { date: "2026-11-16", maxtempC: "9", mintempC: "4", maxtempF: "48", mintempF: "39", hourly: [] },
        { date: "2026-11-17", maxtempC: "7", mintempC: "-1", maxtempF: "45", mintempF: "30", hourly: [{ time: "1100", weatherCode: "200" }, { time: "1400" }] },
        { date: "2026-11-18", maxtempC: "8", mintempC: "2", maxtempF: "46", mintempF: "36", hourly: [{ time: "1200", weatherCode: "113" }] }
      ]
    }
  }
  function meteo() {
    return {
      current: { temperature_2m: 11.6, apparent_temperature: 9.4, relative_humidity_2m: 81, wind_speed_10m: 14.2, weather_code: 61, is_day: 0 },
      daily: { time: ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18"], temperature_2m_max: [13.2, 12.5, null, 10, 3], temperature_2m_min: [7.7, 6.1, 5, -2.5, 1], weather_code: [3, 95, null, 77, ""] }
    }
  }
  function cork() {
    return { name: "Cork", description: "Munster, Ireland", latitude: 51.9, longitude: -8.47 }
  }
  function places() {
    return JSON.stringify({ results: [
      { name: "Cork", admin1: "Munster", country: "Ireland", latitude: 51.9, longitude: -8.47 },
      { name: "", country: "Nowhere", latitude: 1, longitude: 2 },
      { name: "Half", latitude: 1 },
      null,
      { name: 5, latitude: 0, longitude: 0 },
      { name: "Nulls", country: "Z", latitude: null, longitude: null },
      { name: "Corcaigh", admin1: "", country: "Éire", latitude: "51.9", longitude: "-8.4" }
    ] })
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same([Model.readPlace('{"name":"  Cork ","latitude":51.9,"longitude":-8.47}'), Model.readPlace('{"name":"Cork","latitude":"51.9","longitude":"x"}'), Model.readPlace('{"name":7,"latitude":"0","longitude":"0"}'), Model.readPlace('{"latitude":1}')], [{"name":"Cork","latitude":51.9,"longitude":-8.47},{"name":"Cork","latitude":null,"longitude":null},{"name":"","latitude":0,"longitude":0},{"name":"","latitude":null,"longitude":null}]), "a place kept")
    check(same(["", "garbage", "null", "[1,2]", "\"Cork\"", " {\"name\":\"Cork\"} "].map(t => Model.readPlace(t)).concat([Model.readPlace(null), Model.readPlace(undefined)]), [{"name":"","latitude":null,"longitude":null},{"name":"","latitude":null,"longitude":null},{"name":"","latitude":null,"longitude":null},{"name":"","latitude":null,"longitude":null},{"name":"","latitude":null,"longitude":null},{"name":"Cork","latitude":null,"longitude":null},{"name":"","latitude":null,"longitude":null},{"name":"","latitude":null,"longitude":null}]), "none kept")
    check(same([Model.keepArguments("", 1, 2), Model.keepArguments("Cork", 51.9, -8.47), Model.keepArguments("Cork", null, null), Model.keepArguments("Cork", 51.9, null), Model.keepArguments("Cork", 0, 0), Model.keepArguments(null, null, null)], [["--clear"],["--set","Cork","51.9,-8.47"],["--set","Cork"],["--set","Cork"],["--set","Cork","0,0"],["--clear"]]), "the arguments to keep a place")
    check(same([Model.hasCoordinates({ latitude: 1, longitude: 2 }), Model.hasCoordinates({ latitude: null, longitude: 2 }), Model.hasCoordinates({ latitude: "0", longitude: "0" }), Model.hasCoordinates({}), Model.hasCoordinates({ latitude: "x", longitude: 3 })], [true,false,true,false,false]), "a place with coordinates")
    check(same([Model.wttrQuery({ name: "Cork", latitude: 51.9, longitude: -8.47 }), Model.wttrQuery({ name: " São Paulo " }), Model.wttrQuery({ name: " " }), Model.wttrQuery({}), Model.wttrQuery({ name: "Cork", latitude: "x", longitude: 1 }), Model.wttrQuery({ name: "a&b/c", latitude: null, longitude: null }), Model.wttrQuery({ latitude: "0", longitude: "-0.5" })], ["51.9,-8.47","S%C3%A3o%20Paulo","","","Cork","a%26b%2Fc","0,-0.5"]), "what wttr.in is asked for")
    check(same([Model.meteoPoint({ latitude: 51.9, longitude: -8.47 }, { latitude: "1", longitude: "2" }), Model.meteoPoint({}, { latitude: "51.900", longitude: "-8.470" }), Model.meteoPoint({}, null), Model.meteoPoint({}, { latitude: "1" }), Model.meteoPoint({ latitude: 3 }, { latitude: "1", longitude: "2" }), Model.meteoPoint({ latitude: "x", longitude: "y" }, undefined), Model.meteoPoint({}, { latitude: 0, longitude: 5 }), Model.meteoPoint({}, Model.areaOf(wttr()))], [{"latitude":51.9,"longitude":-8.47},{"latitude":51.9,"longitude":-8.47},null,null,{"latitude":1,"longitude":2},null,null,{"latitude":51.9,"longitude":-8.47}]), "where Open-Meteo is asked about")
    check(same(["Cork, Munster, Ireland", "51.9,-8.47", "", "  Cork  ", "-33.1,151", "Town", "1,2,3", " 51.9, -8.4 "].map(t => Model.detectedTown(t)).concat([Model.detectedTown(null)]), ["Cork","51.9,-8.47",null,"Cork","-33.1,151","Town","1","51.9",null]), "the town wttr.in places the address in")
    check(same(Model.suggestions(places()), [{"name":"Cork","description":"Munster, Ireland","latitude":51.9,"longitude":-8.47},{"name":"5","description":"","latitude":0,"longitude":0},{"name":"Nulls","description":"Z","latitude":null,"longitude":null},{"name":"Corcaigh","description":"Éire","latitude":"51.9","longitude":"-8.4"}]), "the places found")
    check(same(["{}", "garbage", "", "null", "5", '{"results":null}', '{"results":[]}', '{"results":"abc"}', '{"results":{"name":"x"}}'].map(t => Model.suggestions(t)).concat([Model.suggestions(null), Model.suggestions(undefined)]), [[],[],[],[],[],[],[],[],[],[],[]]), "and none")
    check(same([Model.chosenPlace("", [cork()], 0), Model.chosenPlace("  cork ", [], 0), Model.chosenPlace("cork", [cork(), { name: "Two" }], 1), Model.chosenPlace("cork", [cork(), { name: "Two" }], 5), Model.chosenPlace("cork", [cork()], -3), Model.chosenPlace("cork", null, 0), Model.chosenPlace("cork", [cork(), { name: "Two" }], "x"), Model.chosenPlace("cork", [cork(), { name: "Two" }], "1"), Model.chosenPlace(null, [cork()], 0), Model.chosenPlace("x", [null, cork()], 0)], [{"name":"","latitude":null,"longitude":null},{"name":"cork","latitude":null,"longitude":null},{"name":"Two"},{"name":"Two"},{"name":"Cork","description":"Munster, Ireland","latitude":51.9,"longitude":-8.47},{"name":"cork","latitude":null,"longitude":null},{"name":"Cork","description":"Munster, Ireland","latitude":51.9,"longitude":-8.47},{"name":"Two"},{"name":"","latitude":null,"longitude":null},{"name":"x","latitude":null,"longitude":null}]), "the place Enter sets")
    check(same([30, "45", 0, -5, null, "x", 0.5, "7.9", undefined, "", 1].map(s => Model.refreshMinutes(s)), [30,45,15,1,15,15,15,7,15,15,1]), "how often the services are asked")
    check(same([Model.parsed('{"a":1}'), Model.parsed(" [1] "), Model.parsed(""), Model.parsed(null), Model.parsed("{bad"), Model.parsed("\n5\n")], [{"a":1},[1],null,null,null,5]), "an answer read")
    check(same([Model.TOWN_URL, Model.wttrUrl("51.9,-8.47"), Model.wttrUrl(""), Model.meteoUrl(null), Model.meteoUrl({ latitude: 51.9, longitude: -8.47 }), Model.meteoUrl({ latitude: "1 2", longitude: 0 }), Model.searchUrl("São Paulo&x")], ["https://wttr.in/?format=%l","https://wttr.in/51.9,-8.47?format=j1","https://wttr.in/?format=j1","","https://api.open-meteo.com/v1/forecast?latitude=51.9&longitude=-8.47&daily=weather_code,temperature_2m_max,temperature_2m_min&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day&forecast_days=4&timezone=auto","https://api.open-meteo.com/v1/forecast?latitude=1%202&longitude=0&daily=weather_code,temperature_2m_max,temperature_2m_min&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day&forecast_days=4&timezone=auto","https://geocoding-api.open-meteo.com/v1/search?name=S%C3%A3o%20Paulo%26x&count=5&language=en&format=json"]), "the addresses asked")
    check(same([Model.areaOf(wttr()), Model.areaOf({}), Model.areaOf(null), Model.areaOf({ nearest_area: [] }), Model.named(wttr().nearest_area[0].areaName), Model.named([]), Model.named(null), Model.named(undefined)], [{"areaName":[{"value":"Cork"}],"country":[{"value":"Ireland"}],"latitude":"51.900","longitude":"-8.470"},null,null,null,"Cork","","",""]), "the area and its names")
    check(same([Model.wttrNow(wttr()), Model.wttrNow({}), Model.wttrNow(null), Model.wttrNow({ current_condition: [] })], [{"tempC":"12","tempF":"54","feelsC":"10","feelsF":"50","windKmh":"15","windMph":"9","humidity":"80","code":"116","meteo":false,"night":false},null,null,null]), "wttr.in's weather now")
    check(same([Model.meteoNow(meteo()), Model.meteoNow({ current: { temperature_2m: null } }), Model.meteoNow({ current: { temperature_2m: 0, is_day: 1 } }), Model.meteoNow(null), Model.meteoNow({}), Model.meteoNow({ current: { temperature_2m: -0.5, apparent_temperature: "x", relative_humidity_2m: "", wind_speed_10m: 0, weather_code: 0, is_day: "0" } })], [{"tempC":"12","tempF":"53","feelsC":"9","feelsF":"49","windKmh":"14","windMph":"9","humidity":"81","code":61,"meteo":true,"night":true},null,{"tempC":"0","tempF":"32","feelsC":"","feelsF":"","windKmh":"","windMph":"","humidity":"","meteo":true,"night":false},null,null,{"tempC":"0","tempF":"31","feelsC":"","feelsF":"","windKmh":"0","windMph":"0","humidity":"","code":0,"meteo":true,"night":true}]), "Open-Meteo's")
    check(same([Model.nowText(Model.wttrNow(wttr()), false), Model.nowText(Model.wttrNow(wttr()), true), Model.nowText(Model.meteoNow(meteo()), false), Model.nowText(Model.meteoNow(meteo()), true), Model.nowText(null, false), Model.nowText({ tempC: "", feelsC: "", windKmh: "", humidity: "" }, false), Model.nowText({ tempC: 0, feelsC: 0, windKmh: 0, humidity: 0 }, false), Model.nowText({}, true)], [{"temp":"12","feels":"10°C","wind":"15 km/h","humidity":"80%"},{"temp":"54","feels":"50°F","wind":"9 mph","humidity":"80%"},{"temp":"12","feels":"9°C","wind":"14 km/h","humidity":"81%"},{"temp":"53","feels":"49°F","wind":"9 mph","humidity":"81%"},{"temp":"","feels":"","wind":"","humidity":""},{"temp":"","feels":"","wind":" km/h","humidity":"%"},{"temp":"0","feels":"0°C","wind":"0 km/h","humidity":"0%"},{"temp":"undefined","feels":"","wind":"undefined mph","humidity":"undefined%"}]), "the weather now in words")
    check(same([Model.degrees("5"), Model.degrees(0), Model.degrees(""), Model.degrees(null), Model.degrees(undefined), Model.degrees(-3)], ["5°","0°","","","","-3°"]), "a day's high or low")
    check(same([Model.nowGlyph(Model.wttrNow(wttr()), "x"), Model.nowGlyph(Model.meteoNow(meteo()), "x"), Model.nowGlyph({ code: null }, "x"), Model.nowGlyph(null, undefined), Model.nowGlyph({}, "y"), Model.nowGlyph({ meteo: true, code: 0, night: false }, "x"), Model.nowGlyph({ meteo: true, code: 0, night: true }, "x"), Model.nowGlyph({ meteo: false, code: "113", night: true }, "x"), Model.nowGlyph({ meteo: false, code: "", night: false }, "x")], ["","","x","","y","","","",""]), "the glyph now")
    check(same(Array.from({ length: 401 }, (_, c) => Model.nowGlyph({ code: c, meteo: false }, "")).join("|"), "||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||"), "wttr.in's glyphs")
    check(same(Array.from({ length: 101 }, (_, c) => Model.nowGlyph({ code: c, meteo: true, night: false }, "")).join("|"), "||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||"), "Open-Meteo's by day")
    check(same(Array.from({ length: 101 }, (_, c) => Model.nowGlyph({ code: String(c), meteo: true, night: true }, "")).join("|"), "||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||"), "and by night")
    check(same([Model.forecastDays(wttr(), meteo(), "2026-11-14"), Model.forecastDays(wttr(), null, "2026-11-14"), Model.forecastDays(wttr(), { daily: { time: ["2026-11-13"] } }, "2026-11-14"), Model.forecastDays(null, null, "2026-11-14")], [[{"date":"2026-11-15","highC":"13","lowC":"6","highF":"55","lowF":"43","glyph":""},{"date":"2026-11-16","highC":"","lowC":"5","highF":"","lowF":"41","glyph":""},{"date":"2026-11-17","highC":"10","lowC":"-2","highF":"50","lowF":"28","glyph":""}],[{"date":"2026-11-15","highC":"11","lowC":"6","highF":"52","lowF":"43","glyph":""},{"date":"2026-11-16","highC":"9","lowC":"4","highF":"48","lowF":"39","glyph":""},{"date":"2026-11-17","highC":"7","lowC":"-1","highF":"45","lowF":"30","glyph":""}],[{"date":"2026-11-15","highC":"11","lowC":"6","highF":"52","lowF":"43","glyph":""},{"date":"2026-11-16","highC":"9","lowC":"4","highF":"48","lowF":"39","glyph":""},{"date":"2026-11-17","highC":"7","lowC":"-1","highF":"45","lowF":"30","glyph":""}],[]]), "the days ahead")
    check(same([Model.forecastDays(wttr(), meteo(), ""), Model.forecastDays(null, meteo(), null), Model.forecastDays(wttr(), {}, "2026-11-16"), Model.forecastDays(null, { daily: { time: ["2026-11-15T00:00", "", null, "2026-11-16"] } }, "2026-11-14"), Model.forecastDays({ weather: [] }, { daily: {} }, "2026-11-14")], [[{"date":"2026-11-14","highC":"13","lowC":"8","highF":"56","lowF":"46","glyph":""},{"date":"2026-11-15","highC":"13","lowC":"6","highF":"55","lowF":"43","glyph":""},{"date":"2026-11-16","highC":"","lowC":"5","highF":"","lowF":"41","glyph":""}],[{"date":"2026-11-14","highC":"13","lowC":"8","highF":"56","lowF":"46","glyph":""},{"date":"2026-11-15","highC":"13","lowC":"6","highF":"55","lowF":"43","glyph":""},{"date":"2026-11-16","highC":"","lowC":"5","highF":"","lowF":"41","glyph":""}],[{"date":"2026-11-17","highC":"7","lowC":"-1","highF":"45","lowF":"30","glyph":""},{"date":"2026-11-18","highC":"8","lowC":"2","highF":"46","lowF":"36","glyph":""}],[{"date":"2026-11-15T00:00","highC":"","lowC":"","highF":"","lowF":"","glyph":""},{"date":"2026-11-16","highC":"","lowC":"","highF":"","lowF":"","glyph":""}],[]]), "from any day")
    check(same([Model.dayName("2026-11-15", d => d.getDate() + "/" + d.getHours()), Model.dayName("", d => "x"), Model.dayName("garbage", d => "x"), Model.dayName(null, d => "x")], ["15/12","","",""]), "a day's name")
    check(same([["imperial", "de_DE", "Germany"], ["Metric", "en_US", "USA"], ["", "de_DE", "United States"], ["", "en_US.UTF-8", ""], ["", "de_DE", ""], ["auto", "en_US", "Germany"], [null, "my_MM", null], ["", "en-LR", ""], ["", "en_USA", ""], ["", "en.US", ""], ["", "en_GB", "united_states"], ["", "", "U.S.A"], ["", "", " Burma "], ["", "", "Myanmar"], ["", "mya", ""], ["", "my", ""], [" IMPERIAL ", "", ""], ["", "en_US@x", "Liberia"], ["", "en_LR", "Ireland"], ["", "C", "united-states-of-america"], ["", "en__US", ""], ["", "my.UTF-8", ""], ["", null, undefined]].map(([u, l, c]) => Model.imperial(u, l, c)), [true,false,true,true,false,false,true,true,false,true,true,false,true,true,false,true,true,true,false,true,false,true,false]), "the units")

    console.log("DONE")
    Qt.quit()
  }
}
