//! nova-calendar-sync, the Calendar's two-way sync, against a CalDAV server on
//! 127.0.0.1: the fake one (support/fake.rs), or Radicale where
//! NOVA_TEST_RADICALE=1 and radicale is on PATH (`pip install radicale` in a
//! venv will do). The test plays the phone, changing the server's calendars
//! over HTTP, and the shell, changing the calendar's files as Store.qml writes
//! them. Each scenario has a computer of its own (a scratch home, a port of
//! its own) and prints "ok" or "FAIL" for each check; it fails at its end if
//! any did. No test reaches a real server, or the computer's keyring:
//! secret-tool is a stub that keeps the secrets in scratch files, except in
//! the one test that runs the real one on a keyring and a D-Bus session of its
//! own. Scenarios that need something only the fake can do (no sync tokens,
//! Google's sign-in, a read-only calendar) run on the fake whatever is asked.

mod support;

use nova_calendar::ical::{self, Component};
use nova_calendar::json::{self, Json};
use nova_calendar::store::swap_in;
use nova_calendar::zone::vtimezone;
use nova_calendar::{http, normalize_url};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use support::codec::form;
use support::fake::{Fake, OAuth};
use support::pc::*;

const HOME_DAY: [&str; 2] = [":20261110T100000Z", ":20261110T110000Z"];

/// A one-hour event of <start> and <end> in UTC.
fn hour(uid: &str, title: &str, start: &str, end: &str) -> String {
    vevent(uid, title, start, end, &[])
}

fn same_server(a: &str, b: &str) -> bool {
    http::same_server(a, b).expect("two addresses")
}

fn ids(pc: &Pc) -> Vec<String> {
    pc.calendars()
        .iter()
        .map(|c| c.text("id").to_string())
        .collect()
}

fn title(c: &Component) -> String {
    summary(Some(&vec![c.clone()])).unwrap_or_default()
}

fn names(pc: &Pc) -> Vec<String> {
    let mut names: Vec<String> = pc
        .calendars()
        .iter()
        .map(|c| c.text("name").to_string())
        .collect();
    names.sort();
    names
}

fn modified(pc: &Pc, name: &str) -> std::time::SystemTime {
    fs::metadata(pc.path(name))
        .and_then(|m| m.modified())
        .expect("the file is there")
}

fn has_request(server: &Server, wanted: &str) -> bool {
    server
        .fake_server()
        .state()
        .log
        .iter()
        .any(|(m, _)| m == wanted)
}

fn sent_anything(server: &Server) -> bool {
    server
        .fake_server()
        .state()
        .log
        .iter()
        .any(|(m, _)| m == "PUT" || m == "DELETE")
}

fn has_calendar_files(pc: &Pc) -> bool {
    pc.files().iter().any(|f| f != "calendar.ics")
}

// ---- scenarios

#[test]
fn discovery_finds_the_principal_the_calendar_home_and_its_calendars_and_sets_and_removes() {
    let pc = Pc::new("discovery");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    server.make_calendar("work", "Work", &["VEVENT"], "#1BADF8FF");
    let bad = pc.run(
        &["add"],
        Some(&request(&[
            ("type", "caldav"),
            ("url", &server.url()),
            ("user", &server.user),
            ("password", "wrong"),
        ])),
    );
    pc.check(
        bad.code == 3 && bad.stderr.contains("not accepted"),
        format!(
            "a wrong password is refused, in words ({}: {})",
            bad.code,
            bad.stderr.trim()
        ),
    );
    let plain = pc.run(
        &["add"],
        Some(&request(&[
            ("type", "caldav"),
            ("url", "http://calendar.example.org/"),
            ("user", "a"),
            ("password", "b"),
        ])),
    );
    pc.check(
        plain.code == 1 && plain.stderr.contains("https://"),
        "a password is not sent in the clear to another computer",
    );
    let added = pc.add(&server);
    let mut found: Vec<String> = added
        .get("calendars")
        .and_then(Json::as_array)
        .map(|a| a.iter().map(|c| c.text("name").to_string()).collect())
        .unwrap_or_default();
    found.sort();
    pc.check(
        found == ["Home", "Work"],
        format!("it finds the account's calendars, and only calendars: {found:?}"),
    );
    let config = pc.config();
    let (home, work) = (pc.calendar("Home"), pc.calendar("Work"));
    let first = &config
        .get("calendars")
        .and_then(Json::as_array)
        .expect("calendars")[0];
    pc.check(
        first.text("id") == "local" && first.text("kind") == "local",
        "the calendar on this computer stays first",
    );
    pc.check(
        home.is("tasks") && home.is("events") && !work.is("tasks") && !home.is("readOnly"),
        "what each calendar takes: events, tasks",
    );
    pc.check(
        home.text("color") == "red" && work.text("color") == "blue",
        format!(
            "the server's colours become the theme's nearest ({}, {})",
            home.text("color"),
            work.text("color")
        ),
    );
    pc.check(
        home.is("shown") && work.is("shown"),
        "found calendars are shown",
    );
    if !server.is_radicale() {
        pc.check(
            server
                .fake_server()
                .state()
                .log
                .contains(&("PROPFIND".into(), "/.well-known/caldav".into())),
            "a server's address is looked up at /.well-known/caldav first",
        );
    }
    let text = fs::read_to_string(pc.list_path()).expect("the list");
    pc.check(
        !text.contains(&server.password),
        "the password is not in the calendar list",
    );
    pc.check(
        pc.secrets().contains(&server.password),
        "it is in the keyring",
    );
    pc.check(
        fs::metadata(pc.list_path())
            .expect("the list")
            .permissions()
            .mode()
            & 0o777
            == 0o600,
        "the list is the user's alone",
    );
    let again = pc.add_quietly(&server);
    pc.check(
        again.code == 1 && again.stderr.contains("already"),
        "the same account is not added twice",
    );
    // set, and remove
    let id = home.text("id").to_string();
    pc.check(
        pc.run(
            &["set", &id, "shown=false", "color=green", "name=Family"],
            None,
        )
        .code
            == 0,
        "set runs",
    );
    let home = pc
        .calendars()
        .into_iter()
        .find(|c| c.text("id") == id)
        .expect("the calendar");
    pc.check(
        !home.is("shown") && home.text("color") == "green" && home.text("name") == "Family",
        "a calendar hidden, coloured and named",
    );
    pc.check(
        pc.run(&["set", &id, "color=purple"], None).code == 1,
        "a colour that is not the theme's is refused",
    );
    pc.sync();
    pc.check(pc.path("Work").exists(), "a synced calendar has its file");
    let account = pc.account();
    pc.check(pc.run(&["remove", &account], None).code == 0, "remove runs");
    let left = pc.config();
    pc.check(
        left.get("accounts")
            .and_then(Json::as_array)
            .is_some_and(|a| a.is_empty())
            && ids(&pc) == ["local"],
        "the account and its calendars are gone from the list",
    );
    pc.check(!has_calendar_files(&pc), "and their files");
    pc.check(pc.secrets().is_empty(), "and the password from the keyring");
    server.stop();
}

#[test]
fn two_way_made_changed_moved_and_deleted_here_and_on_the_phone() {
    let pc = Pc::new("two-way");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    phone.put(
        "home",
        "dentist.ics",
        &vcal(
            &[&hour(
                "dentist@phone",
                "Dentist",
                ";TZID=Europe/Rome:20261110T100000",
                ";TZID=Europe/Rome:20261110T110000",
            )],
            ROME,
        ),
    );
    phone.put(
        "home",
        "trip.ics",
        &vcal(
            &[&hour(
                "trip@phone",
                "Trip",
                ";VALUE=DATE:20261112",
                ";VALUE=DATE:20261115",
            )],
            "",
        ),
    );
    phone.put(
        "home",
        "milk.ics",
        &vcal(
            &["BEGIN:VTODO\r\nUID:milk@phone\r\nDTSTAMP:20261101T000000Z\r\nSUMMARY:Buy milk\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\n"],
            "",
        ),
    );
    pc.add(&server);
    let done = pc.sync();
    pc.check(
        done.code == 0 && pc.status_of(&pc.account()).text("state") == "ok",
        "the first sync runs, and says so",
    );
    let items = pc.items("Home");
    pc.check(
        items.uids() == ["dentist@phone", "milk@phone", "trip@phone"],
        format!("the server's events and tasks come in: {:?}", items.uids()),
    );
    let text = pc.text("Home");
    pc.check(
        text.contains("BEGIN:VTIMEZONE") && text.contains("TZID:Europe/Rome"),
        "with the zones they name",
    );

    // Made, changed, moved and deleted here.
    pc.edit("Home", |cal| {
        new_component(
            cal,
            &vevent(
                "new@nova",
                "Lunch\\, with Sam",
                ";TZID=Europe/Rome:20261111T130000",
                ";TZID=Europe/Rome:20261111T140000",
                &["DESCRIPTION:Line one\\nline two"],
            ),
        )
    });
    pc.edit("Home", |cal| {
        set_prop(cal, "dentist@phone", "SUMMARY", "Dentist (Dr Rossi)")
    });
    pc.edit("Home", |cal| {
        set_prop(cal, "trip@phone", "DTSTART;VALUE=DATE", "20261113");
        set_prop(cal, "trip@phone", "DTEND;VALUE=DATE", "20261116");
    });
    pc.edit("Home", |cal| remove_item(cal, "milk@phone"));
    pc.sync();
    let on_phone = phone.all("home");
    let get = |uid: &str| on_phone.get(uid).cloned().unwrap_or_default();
    pc.check(
        get("new@nova").contains("SUMMARY:Lunch\\, with Sam"),
        "an event made here reaches the server",
    );
    pc.check(
        get("new@nova").contains("BEGIN:VTIMEZONE") && get("new@nova").contains("TZID:Europe/Rome"),
        "with a VTIMEZONE for the zone it names",
    );
    pc.check(
        get("dentist@phone").contains("Dentist (Dr Rossi)"),
        "a title changed here reaches it",
    );
    pc.check(
        get("trip@phone").contains("DTSTART;VALUE=DATE:20261113"),
        "an event moved here reaches it",
    );
    pc.check(
        !on_phone.contains_key("milk@phone"),
        "a task deleted here is deleted there",
    );

    // Made, changed and deleted on the phone.
    phone.put(
        "home",
        "gym.ics",
        &vcal(
            &[&hour(
                "gym@phone",
                "Gym",
                ":20261114T170000Z",
                ":20261114T180000Z",
            )],
            "",
        ),
    );
    let name = phone.name_of("home", "dentist@phone");
    phone.put(
        "home",
        &name,
        &get("dentist@phone")
            .replace("Dentist (Dr Rossi)", "Dentist\\, moved")
            .replace("20261110T110000", "20261110T160000")
            .replace("20261110T100000", "20261110T150000"),
    );
    phone.delete("home", &phone.name_of("home", "trip@phone"));
    pc.sync();
    let items = pc.items("Home");
    pc.check(
        items.contains("gym@phone"),
        "an event made on the phone comes in",
    );
    pc.check(
        summary(items.get("dentist@phone")).as_deref() == Some("Dentist, moved")
            && items
                .get("dentist@phone")
                .is_some_and(|g| ical::canon(&g[0]).contains("20261110T150000")),
        "one changed there comes in changed",
    );
    pc.check(
        !items.contains("trip@phone"),
        "one deleted there is deleted here",
    );
    pc.check(
        pc.text("Home").contains("Line one\\nline two"),
        "text is kept as it was written",
    );
    let before = pc.text("Home");
    let mtime = modified(&pc, "Home");
    pc.sync();
    pc.check(
        pc.text("Home") == before && modified(&pc, "Home") == mtime,
        "with nothing changed, the file is left alone",
    );
    if !server.is_radicale() {
        pc.check(
            has_request(&server, "REPORT"),
            "the changes are asked for with sync-collection",
        );
    }
    server.stop();
}

#[test]
fn a_server_without_sync_collection_is_read_by_its_ctag_and_etags() {
    let pc = Pc::new("fallback");
    let server = Server::fake();
    {
        let mut s = server.fake_server().state();
        s.sync_tokens = false;
        s.etag_on_put = false;
    }
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    phone.put(
        "home",
        "a.ics",
        &vcal(
            &[&hour(
                "a@phone",
                "A",
                ":20261110T100000Z",
                ":20261110T110000Z",
            )],
            "",
        ),
    );
    pc.add(&server);
    pc.sync();
    pc.check(
        pc.items("Home").contains("a@phone"),
        "without sync tokens, the first sync lists the items by their ETags",
    );
    server.fake_server().state().clear_log();
    pc.sync();
    let listed = server
        .fake_server()
        .state()
        .log
        .iter()
        .filter(|(m, p)| m == "PROPFIND" && p == "/alice/cals/home/")
        .count();
    pc.check(
        listed == 1,
        format!("an unchanged ctag spares the listing ({listed} PROPFINDs of the calendar)"),
    );
    pc.edit("Home", |cal| set_prop(cal, "a@phone", "SUMMARY", "A here"));
    pc.sync();
    pc.check(
        Phone::new(&server)
            .item("home", "a@phone")
            .contains("A here"),
        "a change here is sent",
    );
    pc.check(
        has_request(&server, "GET"),
        "with no ETag in the answer, what the server kept is read back",
    );
    phone.put(
        "home",
        "a.ics",
        &Phone::new(&server)
            .item("home", "a@phone")
            .replace("A here", "A there"),
    );
    pc.sync();
    pc.check(
        summary(pc.items("Home").get("a@phone")).as_deref() == Some("A there"),
        "a change there is found by its ETag",
    );
    pc.check(
        !server
            .fake_server()
            .state()
            .log
            .iter()
            .any(|(m, p)| m == "REPORT" && p.contains("sync")),
        "sync-collection is not asked of a server without it",
    );
    server.stop();
}

#[test]
fn changed_on_both_sides_merged_or_both_kept_and_deleted_on_one_side_changed_on_the_other() {
    let pc = Pc::new("conflict");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    for uid in ["same", "apart", "gone-here", "gone-there"] {
        phone.put(
            "home",
            &format!("{uid}.ics"),
            &vcal(
                &[&vevent(
                    uid,
                    &format!("Title {uid}"),
                    ":20261110T100000Z",
                    ":20261110T110000Z",
                    &["LOCATION:Room 1"],
                )],
                "",
            ),
        );
    }
    pc.add(&server);
    pc.sync();
    let texts = phone.all("home");
    // Both change the title differently; one changes the place and the other the title;
    // one deleted here and changed there; one changed here and deleted there.
    phone.put(
        "home",
        &phone.name_of("home", "same"),
        &texts["same"].replace("Title same", "Phone's title"),
    );
    phone.put(
        "home",
        &phone.name_of("home", "apart"),
        &texts["apart"].replace("Title apart", "New title"),
    );
    phone.put(
        "home",
        &phone.name_of("home", "gone-here"),
        &texts["gone-here"].replace("Room 1", "Room 9"),
    );
    phone.delete("home", &phone.name_of("home", "gone-there"));
    pc.edit("Home", |cal| {
        set_prop(cal, "same", "SUMMARY", "Computer's title")
    });
    pc.edit("Home", |cal| set_prop(cal, "apart", "LOCATION", "Room 2"));
    pc.edit("Home", |cal| remove_item(cal, "gone-here"));
    pc.edit("Home", |cal| {
        set_prop(cal, "gone-there", "SUMMARY", "Still wanted")
    });
    pc.sync();
    let items = pc.items("Home");
    let on_phone = phone.all("home");
    let copies = items.titled("Computer's title");
    pc.check(
        summary(items.get("same")).as_deref() == Some("Phone's title"),
        "changed the same way on both sides, the server's version stays the event",
    );
    pc.check(
        copies.len() == 1 && copies[0] != "same",
        "and this computer's is kept beside it, as a copy of its own",
    );
    pc.check(
        copies.first().is_some_and(|c| on_phone.contains_key(c))
            && on_phone
                .get("same")
                .is_some_and(|t| t.contains("Phone's title")),
        "both are on the server too",
    );
    let apart = ical::canon(&items.get("apart").expect("apart")[0]);
    pc.check(
        apart.contains("SUMMARY:New title") && apart.contains("LOCATION:Room 2"),
        "changes to different things are merged",
    );
    pc.check(
        on_phone["apart"].contains("SUMMARY:New title")
            && on_phone["apart"].contains("LOCATION:Room 2"),
        "and the merge is sent",
    );
    pc.check(
        items
            .get("gone-here")
            .is_some_and(|g| ical::canon(&g[0]).contains("Room 9")),
        "deleted here but changed there, it comes back changed",
    );
    pc.check(
        on_phone
            .get("gone-there")
            .is_some_and(|t| t.contains("Still wanted")),
        "changed here but deleted there, it is sent again",
    );
    pc.check(
        items.len() == 5 && on_phone.len() == 5,
        format!(
            "and nothing else: {} here, {} there",
            items.len(),
            on_phone.len()
        ),
    );
    pc.sync();
    pc.check(
        pc.items("Home").len() == 5 && phone.all("home").len() == 5,
        "a second sync changes nothing",
    );
    server.stop();
}

#[test]
fn offline_the_edits_wait_in_the_file_and_are_sent_when_the_server_is_back() {
    let pc = Pc::new("offline");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    phone.put(
        "home",
        "a.ics",
        &vcal(
            &[&hour("a", "A", ":20261110T100000Z", ":20261110T110000Z")],
            "",
        ),
    );
    phone.put(
        "home",
        "b.ics",
        &vcal(
            &[&hour("b", "B", ":20261110T120000Z", ":20261110T130000Z")],
            "",
        ),
    );
    pc.add(&server);
    pc.sync();
    let account = pc.account();
    server.stop();
    pc.edit("Home", |cal| {
        new_component(
            cal,
            &hour(
                "c@nova",
                "Made offline",
                ":20261111T100000Z",
                ":20261111T110000Z",
            ),
        )
    });
    pc.edit("Home", |cal| set_prop(cal, "a", "SUMMARY", "A offline"));
    pc.edit("Home", |cal| remove_item(cal, "b"));
    let done = pc.sync();
    let status = pc.status_of(&account);
    pc.check(
        done.code == 0 && status.text("state") == "offline",
        "with the server out of reach, the sync says offline, not failed",
    );
    let pending = status.get("pending").and_then(Json::as_f64);
    pc.check(
        pending == Some(3.0),
        format!("and how many changes wait: {pending:?}"),
    );
    let items = pc.items("Home");
    pc.check(
        items.contains("c@nova")
            && summary(items.get("a")).as_deref() == Some("A offline")
            && !items.contains("b"),
        "the edits stay in the file",
    );
    server.start();
    pc.sync();
    let on_phone = phone.all("home");
    pc.check(
        on_phone.contains_key("c@nova")
            && on_phone.get("a").is_some_and(|t| t.contains("A offline"))
            && !on_phone.contains_key("b"),
        "back online, they are sent",
    );
    let status = pc.status_of(&account);
    pc.check(
        status.text("state") == "ok" && status.get("pending").and_then(Json::as_f64) == Some(0.0),
        "and nothing waits",
    );
    server.stop();
}

#[test]
fn a_series_with_a_time_moved_on_its_own_changed_on_each_side() {
    let pc = Pc::new("recurring");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    let series = vcal(
        &[
            &vevent(
                "weekly",
                "Planning",
                ";TZID=Europe/Rome:20261012T100000",
                ";TZID=Europe/Rome:20261012T110000",
                &["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10", "EXDATE;TZID=Europe/Rome:20261019T100000"],
            ),
            "BEGIN:VEVENT\r\nUID:weekly\r\nDTSTAMP:20261101T000000Z\r\nRECURRENCE-ID;TZID=Europe/Rome:20261026T100000\r\n\
             DTSTART;TZID=Europe/Rome:20261026T140000\r\nDTEND;TZID=Europe/Rome:20261026T150000\r\nSUMMARY:Planning (later)\r\nEND:VEVENT\r\n",
        ],
        ROME,
    );
    phone.put("home", "weekly.ics", &series);
    pc.add(&server);
    pc.sync();
    let items = pc.items("Home");
    let group = items.get("weekly").cloned().unwrap_or_default();
    pc.check(
        group.len() == 2
            && group
                .iter()
                .any(|c| ical::get(c, "RECURRENCE-ID").is_some()),
        "a series comes in with the time moved on its own",
    );
    // On the phone: the moved time changed again. Here: the series' title.
    let text = phone.item("home", "weekly");
    phone.put(
        "home",
        &phone.name_of("home", "weekly"),
        &text
            .replace("Planning (later)", "Planning (moved twice)")
            .replace("20261026T140000", "20261026T160000"),
    );
    pc.edit("Home", |cal| {
        set_prop(cal, "weekly", "SUMMARY", "Team planning")
    });
    pc.sync();
    let group = pc.items("Home").get("weekly").cloned().expect("the series");
    let master = group
        .iter()
        .find(|c| ical::get(c, "RECURRENCE-ID").is_none())
        .expect("the series' own");
    let moved = group
        .iter()
        .find(|c| ical::get(c, "RECURRENCE-ID").is_some())
        .expect("its moved time");
    pc.check(
        title(master) == "Team planning"
            && ical::canon(master).contains("EXDATE")
            && ical::canon(master).contains("RRULE:FREQ=WEEKLY"),
        "the series keeps the title given here, its rule and what it left out",
    );
    pc.check(
        title(moved) == "Planning (moved twice)" && ical::canon(moved).contains("20261026T160000"),
        "the time moved on its own takes the phone's change",
    );
    let on_phone = phone.item("home", "weekly");
    pc.check(
        on_phone.contains("Team planning")
            && on_phone.contains("Planning (moved twice)")
            && on_phone.matches("BEGIN:VEVENT").count() == 2,
        "and the server has both",
    );
    // Here: another time moved on its own.
    pc.edit("Home", |cal| {
        new_component(
            cal,
            "BEGIN:VEVENT\r\nUID:weekly\r\nRECURRENCE-ID;TZID=Europe/Rome:20261102T100000\r\nDTSTART;TZID=Europe/Rome:20261102T090000\r\n\
             DTEND;TZID=Europe/Rome:20261102T100000\r\nSUMMARY:Team planning (early)\r\nEND:VEVENT\r\n",
        )
    });
    pc.sync();
    pc.check(
        phone.item("home", "weekly").matches("BEGIN:VEVENT").count() == 3,
        "a time moved here reaches the server, in the same item",
    );
    server.stop();
}

#[test]
fn a_file_written_from_before_the_servers_change_does_not_undo_it() {
    let pc = Pc::new("stale");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    phone.put(
        "home",
        "a.ics",
        &vcal(&[&hour("a", "Before", HOME_DAY[0], HOME_DAY[1])], ""),
    );
    pc.add(&server);
    pc.sync();
    let old = pc.text("Home");
    phone.put(
        "home",
        &phone.name_of("home", "a"),
        &phone.item("home", "a").replace("Before", "After"),
    );
    pc.sync();
    // The shell writes from what it had read before the sync changed the file.
    fs::write(pc.path("Home"), old).expect("the old file");
    pc.sync();
    pc.check(
        phone.item("home", "a").contains("After"),
        "a file written from before the server's change does not undo it",
    );
    pc.check(
        summary(pc.items("Home").get("a")).as_deref() == Some("After"),
        "and the file has the change again",
    );
    server.stop();
}

#[test]
fn a_read_only_calendar_sends_nothing_and_keeps_the_servers_version() {
    let pc = Pc::new("readonly");
    let server = Server::fake();
    server.make_calendar("holidays", "Holidays", &["VEVENT"], "#FF2968FF");
    Phone::new(&server).put(
        "holidays",
        "x.ics",
        &vcal(
            &[&hour(
                "xmas",
                "Christmas",
                ";VALUE=DATE:20261225",
                ";VALUE=DATE:20261226",
            )],
            "",
        ),
    );
    server
        .fake_server()
        .state()
        .calendar_mut("holidays")
        .read_only = true;
    pc.add(&server);
    pc.check(
        pc.calendar("Holidays").is("readOnly"),
        "a calendar the user may not write is read-only",
    );
    pc.sync();
    pc.edit("Holidays", |cal| {
        set_prop(cal, "xmas", "SUMMARY", "Mine now")
    });
    pc.edit("Holidays", |cal| {
        new_component(
            cal,
            &hour("new@nova", "New", ":20261110T100000Z", ":20261110T110000Z"),
        )
    });
    server.fake_server().state().clear_log();
    pc.sync();
    let items = pc.items("Holidays");
    pc.check(
        summary(items.get("xmas")).as_deref() == Some("Christmas") && !items.contains("new@nova"),
        "what was changed in it here goes back to the server's",
    );
    pc.check(!sent_anything(&server), "and nothing is sent");
    server.stop();
}

#[test]
fn google_oauth_for_an_installed_app_a_token_renewed_one_taken_back() {
    let mut pc = Pc::new("google");
    let server = Server::fake_as(None, None, Some("access-1"));
    server.make_calendar("primary", "andre@example.org", &["VEVENT"], "#16A765");
    Phone::with_bearer(&server, "access-1").put(
        "primary",
        "a.ics",
        &vcal(&[&hour("a", "From Google", HOME_DAY[0], HOME_DAY[1])], ""),
    );
    fs::create_dir_all(pc.dir.join("nova/calendar")).expect("the shared folder");
    let missing = pc.run(&["google"], None);
    pc.check(
        missing.code == 1,
        "without a client set up, Google sign-in says it is not",
    );
    fs::write(
        pc.dir.join("nova/calendar/google.json"),
        "{\"client_id\": \"nova-test.apps.googleusercontent.com\", \"client_secret\": \"not-secret\"}",
    )
    .expect("the client");
    pc.check(pc.run(&["google"], None).code == 0, "with one, it is");
    server.fake_server().state().oauth = Some(OAuth::new(
        "nova-test.apps.googleusercontent.com",
        "code-1",
        "refresh-SECRET-1",
        "andre@example.org",
    ));
    // The browser: it opens the address, and Google's page (the fake's)
    // signs in at once and sends it back to this computer with a code.
    let asked = pc.dir.join("asked.txt");
    let browser = pc.dir.join("bin/browser");
    fs::write(
        &browser,
        format!(
            "#!/bin/sh\nprintf '%s' \"$1\" > '{}'\ncurl --silent --location --max-time 30 --output /dev/null \"$1\"\n",
            asked.display()
        ),
    )
    .expect("the browser");
    fs::set_permissions(&browser, fs::Permissions::from_mode(0o755)).expect("runnable");
    let url = server.url();
    pc.set_env("NOVA_CALENDAR_BROWSER", &browser.display().to_string());
    pc.set_env("NOVA_CALENDAR_GOOGLE_AUTH", &format!("{url}auth"));
    pc.set_env("NOVA_CALENDAR_GOOGLE_TOKEN", &format!("{url}token"));
    pc.set_env("NOVA_CALENDAR_GOOGLE_CALDAV", &url);
    let done = pc.run(&["add"], Some(&request(&[("type", "google")])));
    let address = fs::read_to_string(&asked).unwrap_or_default();
    let query: BTreeMap<String, String> = form(address.split_once('?').map_or("", |(_, q)| q))
        .into_iter()
        .collect();
    let got = |k: &str| query.get(k).cloned().unwrap_or_default();
    pc.check(
        done.code == 0,
        format!(
            "signing in to Google adds the account ({})",
            done.stderr.trim()
        ),
    );
    pc.check(
        got("code_challenge_method") == "S256"
            && got("redirect_uri").starts_with("http://127.0.0.1:")
            && got("scope").contains("calendar"),
        "the sign-in is OAuth for an installed app: PKCE, the browser back to this computer, the calendar scope",
    );
    pc.check(
        got("access_type") == "offline",
        "and asks for a token that lasts",
    );
    let exchange = server
        .fake_server()
        .state()
        .oauth
        .as_ref()
        .expect("oauth")
        .requests[0]
        .clone();
    pc.check(
        exchange.get("code_verifier").is_some_and(|v| !v.is_empty())
            && exchange.get("client_secret").map(String::as_str) == Some("not-secret"),
        "the code is exchanged with its verifier",
    );
    let config = pc.config();
    let account = config
        .get("accounts")
        .and_then(Json::as_array)
        .expect("accounts")[0]
        .clone();
    pc.check(
        account.text("name") == "andre@example.org" && account.text("type") == "google",
        "the account is named by its address",
    );
    let secret = pc.secrets().first().cloned().unwrap_or_default();
    pc.check(
        secret.contains("refresh-SECRET-1") && !json::dumps(&config).contains("refresh-SECRET-1"),
        "the tokens are in the keyring, not the list",
    );
    pc.sync();
    pc.check(
        pc.items("andre@example.org").contains("a"),
        "Google's calendar syncs with its token",
    );
    // The token runs out: a new one, and on.
    {
        let mut s = server.fake_server().state();
        s.bearer = Some("access-2".into());
        s.oauth.as_mut().expect("oauth").requests.clear();
    }
    Phone::with_bearer(&server, "access-2").put(
        "primary",
        "b.ics",
        &vcal(
            &[&hour(
                "b",
                "Later",
                ":20261111T100000Z",
                ":20261111T110000Z",
            )],
            "",
        ),
    );
    pc.sync();
    let grant = server
        .fake_server()
        .state()
        .oauth
        .as_ref()
        .expect("oauth")
        .requests[0]
        .get("grant_type")
        .cloned();
    pc.check(
        pc.items("andre@example.org").contains("b") && grant.as_deref() == Some("refresh_token"),
        "a refused token is renewed",
    );
    {
        let mut s = server.fake_server().state();
        s.oauth.as_mut().expect("oauth").revoked = true;
        s.bearer = Some("access-3".into());
    }
    pc.sync();
    let status = pc.status_of(account.text("id"));
    pc.check(
        status.text("state") == "signin",
        format!(
            "a token taken back asks to sign in again: {}",
            json::dumps(&status)
        ),
    );
    server.stop();
}

#[test]
fn a_change_made_on_the_phone_as_the_sync_writes_is_not_written_over() {
    // Not one of the Python scenarios: it is what If-Match is for. The phone
    // saves its change after the sync has listed the server and before its
    // PUT arrives, so the PUT meets an ETag that has moved.
    let pc = Pc::new("race");
    let server = Server::fake();
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    phone.put(
        "home",
        "a.ics",
        &vcal(
            &[&vevent(
                "a",
                "Title",
                HOME_DAY[0],
                HOME_DAY[1],
                &["LOCATION:Room 1"],
            )],
            "",
        ),
    );
    pc.add(&server);
    pc.sync();
    let on_phone = phone.item("home", "a").replace("Room 1", "Room 5");
    server
        .fake_server()
        .state()
        .race
        .insert("home/a.ics".into(), on_phone);
    pc.edit("Home", |cal| set_prop(cal, "a", "SUMMARY", "Title here"));
    pc.sync();
    pc.sync();
    let there = phone.item("home", "a");
    pc.check(
        there.contains("LOCATION:Room 5"),
        "a change the phone saved just before the write is not written over",
    );
    pc.check(
        there.contains("SUMMARY:Title here"),
        "and this computer's change is sent with it",
    );
    let here = ical::canon(&pc.items("Home").get("a").expect("a")[0]);
    pc.check(
        here.contains("LOCATION:Room 5") && here.contains("SUMMARY:Title here"),
        "and the file has both",
    );
    server.stop();
}

#[test]
fn icloud_its_own_words_for_a_refused_password_and_its_partitions_as_its_own_server() {
    let pc = Pc::new("icloud");
    pc.check(
        same_server(
            "https://caldav.icloud.com/",
            "https://p42-caldav.icloud.com:443/123/calendars/",
        ),
        "iCloud's password goes on to the partition its calendar home is on",
    );
    pc.check(
        same_server(
            "https://p42-caldav.icloud.com/",
            "https://p07-caldav.icloud.com/123/",
        ) && same_server(
            "https://caldav.icloud.com:443/",
            "https://caldav.icloud.com/x",
        ),
        "and between its partitions",
    );
    pc.check(
        ![
            "https://www.icloud.com/",
            "https://p42-caldav.icloud.com.example.org/",
            "https://evil-caldav.icloud.com/",
            "https://px-caldav.icloud.com/",
            "http://p42-caldav.icloud.com/",
            "https://p42-caldav.icloud.com:8443/",
            "https://caldav.icloud.com.example.org/",
        ]
        .iter()
        .any(|other| same_server("https://caldav.icloud.com/", other)),
        "but to no other host, port or scheme",
    );
    let server = Server::fake_as(Some("me@icloud.com"), Some("abcd-efgh-ijkl-mnop"), None);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let mut pc = pc;
    pc.set_env("NOVA_CALENDAR_ICLOUD", &server.url());
    let bad = pc.run(
        &["add"],
        Some(&request(&[
            ("type", "icloud"),
            ("user", "me@icloud.com"),
            ("password", "wrong"),
        ])),
    );
    pc.check(
        bad.code == 3 && bad.stderr.contains("Apple ID"),
        "iCloud's refusal names the Apple ID and the app-specific password",
    );
    let done = pc.run(
        &["add"],
        Some(&request(&[
            ("type", "icloud"),
            ("user", "me@icloud.com"),
            ("password", "abcd-efgh-ijkl-mnop"),
        ])),
    );
    let accounts = pc.config();
    pc.check(
        done.code == 0
            && accounts
                .get("accounts")
                .and_then(Json::as_array)
                .is_some_and(|a| a[0].text("name") == "iCloud"),
        "an iCloud account is added as iCloud",
    );
    server.stop();
}

#[test]
fn a_subscription_is_read_only_its_address_in_the_keyring_and_a_304_when_unchanged() {
    let pc = Pc::new("subscription");
    let server = Server::fake();
    let feed = vcal(
        &[
            &hour(
                "h1",
                "Holiday",
                ";VALUE=DATE:20261208",
                ";VALUE=DATE:20261209",
            ),
            &hour(
                "m1",
                "Meeting",
                ";TZID=America/New_York:20261110T090000",
                ";TZID=America/New_York:20261110T100000",
            ),
        ],
        "",
    )
    .replace(
        "PRODID:-//Phone//EN",
        "PRODID:-//Phone//EN\r\nX-WR-CALNAME:Team",
    );
    server.fake_server().state().feed = Some(("\"f1\"".into(), feed));
    pc.check(
        normalize_url("webcal://example.org/a.ics", true)
            .as_deref()
            .ok()
            == Some("https://example.org/a.ics"),
        "a webcal address is fetched over https",
    );
    let url = format!(
        "http://127.0.0.1:{}/feed.ics?token=FEED-SECRET-9",
        server.port()
    );
    let done = pc.run(&["subscribe"], Some(&request(&[("url", &url)])));
    pc.check(
        done.code == 0,
        format!("subscribing runs ({})", done.stderr.trim()),
    );
    let cal = pc.calendar("Team");
    pc.check(
        cal.text("kind") == "subscription" && cal.is("readOnly") && !cal.is("tasks"),
        "a subscription is a read-only calendar, named as the feed names itself",
    );
    let text = pc.text("Team");
    pc.check(
        text.contains("Holiday")
            && text.contains("TZID:America/New_York")
            && text.contains("BEGIN:VTIMEZONE"),
        "its events are in its file, with a zone the feed did not define",
    );
    pc.check(
        !fs::read_to_string(pc.list_path())
            .unwrap_or_default()
            .contains("FEED-SECRET-9"),
        "its address is not in the list",
    );
    pc.check(
        pc.secrets().iter().any(|v| v.contains("FEED-SECRET-9")),
        "it is in the keyring",
    );
    server.fake_server().state().clear_log();
    pc.sync();
    pc.check(
        server
            .fake_server()
            .state()
            .log
            .contains(&("GET".into(), "/feed.ics".into()))
            && pc.text("Team") == text,
        "an unchanged feed is not read again (304)",
    );
    let bad = pc.run(
        &["subscribe"],
        Some(&request(&[("url", "ftp://example.org/x.ics")])),
    );
    pc.check(bad.code == 1, "an address that is not a web one is refused");
    pc.check(
        pc.run(&["remove", cal.text("id")], None).code == 0
            && !pc.folder().join(cal.text("file")).exists(),
        "unsubscribing removes its file",
    );
    server.stop();
}

#[test]
fn the_password_is_in_no_file() {
    let pc = Pc::new("secrets");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    pc.add(&server);
    pc.sync();
    let mut leaks = Vec::new();
    let mut folders = vec![pc.home.clone()];
    while let Some(folder) = folders.pop() {
        for entry in fs::read_dir(&folder).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                folders.push(path);
            } else if String::from_utf8_lossy(&fs::read(&path).unwrap_or_default())
                .contains(&server.password)
            {
                leaks.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
    }
    pc.check(
        leaks.is_empty(),
        format!("the password is in no file of the home: {leaks:?}"),
    );
    server.stop();
}

#[test]
fn the_password_goes_to_the_accounts_own_server_only() {
    let pc = Pc::new("foreign");
    let server = Server::fake();
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    Phone::new(&server).put(
        "home",
        "a.ics",
        &vcal(&[&hour("a", "A", HOME_DAY[0], HOME_DAY[1])], ""),
    );
    // Another server, which takes the same password: one sent to it would
    // be let in, and is in its log.
    let other = Fake::new(Some(&server.user), Some(&server.password), None);
    other.add_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let elsewhere = format!("127.0.0.1:{}", other.port());
    pc.check(
        same_server("https://dav.example.org/", "https://dav.example.org:443/a/")
            && same_server("http://dav.example.org/", "https://dav.example.org/a/"),
        "the same server: its scheme, host and port, or the same host over TLS",
    );
    pc.check(
        ![
            "https://example.org/",
            "http://dav.example.org/",
            "https://dav.example.org:8443/",
        ]
        .iter()
        .any(|o| same_server("https://dav.example.org/", o)),
        "another host, port, or plain HTTP is another server",
    );

    let fake = server.fake_server();
    fake.state().home_url = Some(format!("{}alice/cals/", other.url()));
    let done = pc.add_quietly(&server);
    pc.check(
        done.code == 1
            && done
                .stderr
                .contains(&format!("another server, {elsewhere}.")),
        format!(
            "a calendar home on another server is refused ({})",
            done.stderr.trim()
        ),
    );
    pc.check(other.state().log.is_empty(), "and nothing is sent there");
    fake.state().home_url = None;

    fake.state().elsewhere = vec![format!("{}alice/cals/home/", other.url())];
    pc.add(&server);
    pc.check(
        names(&pc) == ["Calendar", "Home"],
        "a calendar listed on another server is left out",
    );
    pc.sync();
    pc.check(
        pc.items("Home").contains("a") && other.state().log.is_empty(),
        "and the sync sends nothing there",
    );

    fake.state().moved.insert(
        "/alice/cals/home/".into(),
        format!("{}alice/cals/home/", other.url()),
    );
    pc.sync();
    let status = pc.status_of(&pc.account());
    pc.check(
        status.text("state") == "error" && status.text("message").contains("another server"),
        format!(
            "a request moved to another server is refused, in words: {}",
            json::dumps(&status)
        ),
    );
    pc.check(
        other.state().log.is_empty(),
        "and not sent there, with its password or without",
    );

    other.state().feed = Some((
        "\"f1\"".into(),
        vcal(
            &[&hour(
                "h1",
                "Holiday",
                ";VALUE=DATE:20261208",
                ";VALUE=DATE:20261209",
            )],
            "",
        )
        .replace(
            "PRODID:-//Phone//EN",
            "PRODID:-//Phone//EN\r\nX-WR-CALNAME:Moved",
        ),
    ));
    fake.state()
        .moved
        .insert("/feed.ics".into(), format!("{}feed.ics", other.url()));
    let feed = format!("http://bob:FEED-PW-7@127.0.0.1:{}/feed.ics", fake.port());
    let done = pc.run(&["subscribe"], Some(&request(&[("url", &feed)])));
    pc.check(
        done.code == 0 && pc.calendars().iter().any(|c| c.text("name") == "Moved"),
        format!(
            "a feed moved to another server is read there ({})",
            done.stderr.trim()
        ),
    );
    let sent = fake.state().requests_to("/feed.ics");
    pc.check(
        sent.last()
            .and_then(|(_, a)| a.as_deref())
            .is_some_and(|a| a.starts_with("Basic ")),
        "its own server has the feed's password",
    );
    pc.check(
        !other.state().log.is_empty() && other.state().auths.iter().all(Option::is_none),
        "the other one does not",
    );
    other.state().feed_private = true;
    let done = pc.run(&["subscribe"], Some(&request(&[("url", &feed)])));
    pc.check(
        done.code == 1
            && done.stderr.contains("another server")
            && other.state().auths.iter().all(Option::is_none),
        "one there that asks for the password does not get it",
    );
    other.stop();
    server.stop();
}

#[test]
fn guard_a_file_gone_emptied_or_mostly_emptied_deletes_nothing_and_an_item_with_no_uid_is_given_one(
) {
    let pc = Pc::new("guard");
    let server = Server::any(&pc);
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    server.make_calendar("small", "Small", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    for i in 0..8 {
        phone.put(
            "home",
            &format!("e{i}.ics"),
            &vcal(
                &[&hour(
                    &format!("e{i}"),
                    &format!("Event {i}"),
                    &format!(":202611{:02}T100000Z", i + 10),
                    &format!(":202611{:02}T110000Z", i + 10),
                )],
                "",
            ),
        );
    }
    for i in 0..2 {
        phone.put(
            "small",
            &format!("s{i}.ics"),
            &vcal(
                &[&hour(
                    &format!("s{i}"),
                    &format!("Small {i}"),
                    &format!(":202611{:02}T100000Z", i + 10),
                    &format!(":202611{:02}T110000Z", i + 10),
                )],
                "",
            ),
        );
    }
    pc.add(&server);
    pc.sync();
    let account = pc.account();
    let path = pc.path("Home");
    pc.check(pc.items("Home").len() == 8, "the calendar comes in");

    phone.put(
        "home",
        "p.ics",
        &vcal(
            &[&hour(
                "p",
                "From the phone",
                ":20261120T100000Z",
                ":20261120T110000Z",
            )],
            "",
        ),
    );
    for what in ["gone", "empty", "that is not a calendar"] {
        match what {
            "gone" => fs::remove_file(&path).expect("the file goes"),
            "empty" => fs::write(&path, "").expect("emptied"),
            _ => fs::write(&path, "not a calendar\n").expect("overwritten"),
        }
        pc.sync();
        let status = pc.status_of(&account);
        pc.check(
            phone.all("home").len() == 9,
            format!("a file {what} deletes nothing on the server"),
        );
        pc.check(
            status.text("state") == "error" && status.text("message").contains("Most of Home"),
            format!("and says so: {}", status.text("message")),
        );
        pc.check(
            pc.items("Home").len() == 9 && pc.items("Home").contains("p"),
            "the file has the server's items again, and its change",
        );
    }

    pc.edit("Home", |cal| {
        for i in 0..5 {
            remove_item(cal, &format!("e{i}"));
        }
        set_prop(cal, "e6", "SUMMARY", "Changed here");
    });
    if !server.is_radicale() {
        server.fake_server().state().clear_log();
    }
    pc.sync();
    let on_phone = phone.all("home");
    pc.check(
        on_phone.len() == 9 && !on_phone["e6"].contains("Changed here"),
        "most of a calendar deleted at once: nothing deleted, nothing sent",
    );
    if !server.is_radicale() {
        pc.check(!sent_anything(&server), "no PUT, no DELETE");
    }
    let items = pc.items("Home");
    pc.check(
        items.len() == 9 && summary(items.get("e6")).as_deref() == Some("Changed here"),
        "the file has them back, and keeps the change made here",
    );
    pc.sync();
    pc.check(
        phone.item("home", "e6").contains("Changed here")
            && pc.status_of(&account).text("state") == "ok",
        "which is sent at the next sync",
    );

    pc.edit("Home", |cal| remove_item(cal, "e0"));
    pc.sync();
    pc.check(
        !phone.all("home").contains_key("e0") && pc.status_of(&account).text("state") == "ok",
        "one deleted here is deleted there",
    );
    pc.edit("Small", |cal| {
        remove_item(cal, "s0");
        remove_item(cal, "s1");
    });
    pc.sync();
    pc.check(
        phone.all("small").is_empty(),
        "a calendar of a few items emptied here is emptied there",
    );

    pc.edit("Home", |cal| {
        new_component(
            cal,
            "BEGIN:VEVENT\r\nDTSTAMP:20261101T000000Z\r\nDTSTART:20261125T100000Z\r\nDTEND:20261125T110000Z\r\nSUMMARY:No UID\r\nEND:VEVENT\r\n",
        )
    });
    pc.sync();
    let uids = pc.items("Home").titled("No UID");
    pc.check(
        uids.len() == 1 && phone.all("home").contains_key(&uids[0]),
        "an item with no UID is given one, and sent",
    );
    server.stop();
}

#[test]
fn listing_a_calendar_the_server_leaves_out_stays_while_it_has_changes_not_sent() {
    let pc = Pc::new("listing");
    let server = Server::fake();
    let phone = Phone::new(&server);
    for name in ["home", "work", "old"] {
        let display = format!("{}{}", name[..1].to_uppercase(), &name[1..]);
        server.make_calendar(name, &display, &["VEVENT", "VTODO"], "#FF2968FF");
        phone.put(
            name,
            "a.ics",
            &vcal(
                &[&hour(
                    &format!("{name}-a"),
                    &display,
                    HOME_DAY[0],
                    HOME_DAY[1],
                )],
                "",
            ),
        );
    }
    pc.add(&server);
    pc.sync();
    let account = pc.account();
    let files = pc.files();
    pc.check(
        files.len() == 3,
        format!("the three calendars' files: {files:?}"),
    );

    let fake = server.fake_server();
    fake.state().unlisted = ["home", "work", "old"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    pc.sync();
    let status = pc.status_of(&account);
    pc.check(
        status.text("state") == "error"
            && status
                .text("message")
                .contains("none of the account's calendars"),
        format!(
            "a listing with no calendars is a failure: {}",
            json::dumps(&status)
        ),
    );
    pc.check(
        pc.calendars().len() == 4 && pc.files() == files,
        "and nothing is forgotten",
    );

    pc.edit("Work", |cal| {
        set_prop(cal, "work-a", "SUMMARY", "Changed here")
    });
    fake.state().unlisted = ["work", "old"].iter().map(|s| s.to_string()).collect();
    pc.sync();
    let listed = names(&pc);
    pc.check(
        !listed.contains(&"Old".to_string()) && listed.contains(&"Home".to_string()),
        "a calendar the server no longer lists goes",
    );
    pc.check(
        pc.calendar("Work").is("gone")
            && summary(pc.items("Work").get("work-a")).as_deref() == Some("Changed here"),
        "one with a change not sent stays, marked gone, with its change",
    );
    let status = pc.status_of(&account);
    pc.check(
        status.text("state") == "error"
            && status
                .text("message")
                .contains("Work is gone from the server"),
        format!("and the status says so: {}", status.text("message")),
    );

    fake.state().unlisted.clear();
    pc.sync();
    let listed = names(&pc);
    pc.check(
        phone.item("work", "work-a").contains("Changed here") && !pc.calendar("Work").is("gone"),
        "listed again, it syncs, and the change is sent",
    );
    pc.check(
        listed.contains(&"Old".to_string()) && pc.status_of(&account).text("state") == "ok",
        "and all is well",
    );

    let config = pc.list_path();
    let files = pc.files();
    let away = config.with_extension("json.away");
    fs::rename(&config, &away).expect("the list goes away");
    pc.sync();
    pc.check(
        pc.files() == files,
        "with no calendar list, no calendar's file is deleted",
    );
    fs::write(&config, "{ not json").expect("a broken list");
    pc.sync();
    pc.check(pc.files() == files, "nor with one that cannot be read");
    fs::rename(&away, &config).expect("the list comes back");
    server.stop();
}

#[test]
fn multiget_an_item_left_out_is_asked_for_again_and_only_a_404_deletes_it() {
    let pc = Pc::new("multiget");
    let server = Server::fake();
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    let phone = Phone::new(&server);
    phone.put(
        "home",
        "a.ics",
        &vcal(&[&hour("a", "A", HOME_DAY[0], HOME_DAY[1])], ""),
    );
    phone.put(
        "home",
        "b.ics",
        &vcal(
            &[&hour("b", "B", ":20261111T100000Z", ":20261111T110000Z")],
            "",
        ),
    );
    pc.add(&server);
    pc.sync();
    let fake = server.fake_server();
    for (way, tokens, tag) in [
        ("sync-collection", true, "One"),
        ("ctag and ETags", false, "Two"),
    ] {
        fake.state().sync_tokens = tokens;
        let texts = phone.all("home");
        phone.put(
            "home",
            "a.ics",
            &texts["a"].replace("SUMMARY:", &format!("SUMMARY:{tag} ")),
        );
        phone.put(
            "home",
            "b.ics",
            &texts["b"].replace("SUMMARY:", &format!("SUMMARY:{tag} ")),
        );
        fake.state().withheld = ["a.ics".to_string()].into();
        pc.sync();
        let items = pc.items("Home");
        let (a, b) = (summary(items.get("a")), summary(items.get("b")));
        pc.check(
            a.as_deref().is_some_and(|a| !a.starts_with(tag))
                && b.as_deref().is_some_and(|b| b.starts_with(tag)),
            format!("{way}: an item the server leaves out of its answer stays as it was"),
        );
        fake.state().withheld.clear();
        pc.sync();
        pc.check(
            summary(pc.items("Home").get("a")).is_some_and(|a| a.starts_with(tag)),
            format!("{way}: and is asked for again at the next sync"),
        );
    }
    fake.state().sync_tokens = true;
    phone.put(
        "home",
        "a.ics",
        &phone.item("home", "a").replace("SUMMARY:", "SUMMARY:Last "),
    );
    fake.state().vanished = ["a.ics".to_string()].into();
    pc.sync();
    let items = pc.items("Home");
    pc.check(
        !items.contains("a") && items.contains("b"),
        "one the server answers 404 for is deleted",
    );
    server.stop();
}

#[test]
fn remove_an_account_removed_while_it_syncs_stays_removed_and_a_file_deleted_while_merged_stays_deleted(
) {
    let pc = Pc::new("remove");
    let server = Server::fake();
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    Phone::new(&server).put(
        "home",
        "a.ics",
        &vcal(&[&hour("a", "A", HOME_DAY[0], HOME_DAY[1])], ""),
    );
    pc.add(&server);
    pc.sync();
    let account = pc.account();
    let fake = server.fake_server();
    fake.state().delay.insert("/alice/cals/".into(), 2.0);
    fake.state().clear_log();
    let mut syncing = pc.start_sync();
    for _ in 0..100 {
        if fake
            .state()
            .log
            .contains(&("PROPFIND".into(), "/alice/cals/".into()))
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let removed = pc.run(&["remove", &account], None);
    let start = Instant::now();
    while syncing
        .try_wait()
        .expect("the sync is waited for")
        .is_none()
    {
        assert!(
            start.elapsed() < Duration::from_secs(60),
            "the sync did not end"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let config = pc.config();
    pc.check(
        removed.code == 0
            && config
                .get("accounts")
                .and_then(Json::as_array)
                .is_some_and(|a| a.is_empty())
            && ids(&pc) == ["local"],
        format!(
            "an account removed while it syncs does not come back: {:?}",
            names(&pc)
        ),
    );
    pc.check(!has_calendar_files(&pc), "nor its files");
    pc.check(pc.status().get(&account).is_none(), "nor its status");

    let folder = pc.dir.join("merge");
    fs::create_dir_all(&folder).expect("a folder");
    let got = swap_in(&folder.join("x.ics"), "new", Some("old"));
    let left = fs::read_dir(&folder).map(|d| d.count()).unwrap_or(99);
    pc.check(
        matches!(got, Ok(None)) && left == 0,
        format!("a file deleted while it is merged stays deleted, and the sync goes on ({got:?})"),
    );
    server.stop();
}

#[test]
fn slow_a_server_sending_a_byte_at_a_time_is_stopped_at_the_time_limit() {
    let mut pc = Pc::new("slow");
    let server = Server::fake();
    let feed = vcal(
        &(0..5)
            .map(|i| {
                hour(
                    &format!("h{i}"),
                    &format!("Holiday {i}"),
                    &format!(";VALUE=DATE:202612{:02}", i + 1),
                    &format!(";VALUE=DATE:202612{:02}", i + 2),
                )
            })
            .collect::<Vec<_>>()
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        "",
    );
    server.fake_server().state().feed = Some(("\"f1\"".into(), feed.clone()));
    let done = pc.run(
        &["subscribe"],
        Some(&request(&[("url", &format!("{}feed.ics", server.url()))])),
    );
    pc.check(done.code == 0, "a feed is subscribed to");
    let cal = pc
        .calendars()
        .into_iter()
        .find(|c| c.text("kind") == "subscription")
        .expect("a subscription");
    {
        let mut s = server.fake_server().state();
        s.feed = Some(("\"f2\"".into(), feed.replace("Holiday", "Day")));
        s.trickle = 0.02;
    }
    pc.set_env("NOVA_CALENDAR_SYNC_SECONDS", "1");
    let start = Instant::now();
    pc.sync();
    let took = start.elapsed().as_secs_f64();
    let status = pc.status_of(cal.text("id"));
    pc.check(
        took < 8.0
            && status.text("state") == "error"
            && status.text("message").contains("too long"),
        format!(
            "a server sending a byte at a time is stopped at the time limit ({took:.1}s, {})",
            status.text("message")
        ),
    );
    server.stop();
}

#[test]
fn zones_a_file_names_without_their_vtimezone_come_from_the_zone_database() {
    let pc = Pc::new("zones");
    let parts = |tz: &Component| -> Vec<(String, String)> {
        tz.children
            .iter()
            .map(|c| (c.name.clone(), ical::canon(c)))
            .collect()
    };
    let part = |parts: &[(String, String)], name: &str| -> String {
        parts
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, t)| t.clone())
            .unwrap_or_default()
    };
    let rome = parts(&vtimezone("Europe/Rome").expect("Rome"));
    let (daylight, standard) = (part(&rome, "DAYLIGHT"), part(&rome, "STANDARD"));
    pc.check(
        daylight.contains("RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU")
            && daylight.contains("TZOFFSETTO:+0200")
            && daylight.contains("DTSTART:19700329T020000"),
        "Rome's summer time: the last Sunday of March, at two",
    );
    pc.check(
        standard.contains("RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU")
            && standard.contains("DTSTART:19701025T030000"),
        "and its end: the last Sunday of October, at three",
    );
    let ny = parts(&vtimezone("America/New_York").expect("New York"));
    pc.check(
        part(&ny, "DAYLIGHT").contains("BYMONTH=3;BYDAY=2SU")
            && part(&ny, "STANDARD").contains("BYMONTH=11;BYDAY=1SU")
            && part(&ny, "DAYLIGHT").contains("TZOFFSETFROM:-0500"),
        "New York's, on the second and first Sundays",
    );
    let kolkata = parts(&vtimezone("Asia/Kolkata").expect("Kolkata"));
    pc.check(
        kolkata.len() == 1
            && kolkata[0].0 == "STANDARD"
            && kolkata[0].1.contains("TZOFFSETTO:+0530"),
        "a zone with no summer time has one part",
    );
    let nuuk = vtimezone("America/Nuuk");
    pc.check(
        nuuk.as_ref()
            .is_some_and(|z| ical::serialize(std::slice::from_ref(z)).contains("RDATE")),
        "a rule a yearly RRULE cannot say is written as its changes",
    );
    pc.check(
        vtimezone("Nowhere/Known").is_none() && vtimezone("../etc/passwd").is_none(),
        "no zone for a name that is none",
    );
}

// ---- the login keyring

fn on_path(program: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {program}")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// The real gnome-keyring, of a scratch home, on a D-Bus session of its own:
/// this test starts the session and the keyring, and runs the next test in
/// it. Nothing of the user's own session or keyring is in its environment.
#[test]
fn the_login_keyring_itself_on_a_dbus_session_of_its_own() {
    if !(on_path("gnome-keyring-daemon") && on_path("secret-tool") && on_path("dbus-run-session")) {
        println!("skipped: this needs gnome-keyring, secret-tool and dbus-run-session");
        return;
    }
    let scratch =
        std::env::temp_dir().join(format!("nova-calsync.{}.keyring-outer", std::process::id()));
    let _ = fs::remove_dir_all(&scratch);
    let home = scratch.join("keyring-home");
    let run = scratch.join("run");
    for dir in [&home, &run] {
        fs::create_dir_all(dir).expect("a scratch folder");
    }
    fs::set_permissions(&run, fs::Permissions::from_mode(0o700)).expect("a private runtime folder");
    let exe = std::env::current_exe().expect("this test's program");
    let out = Command::new("dbus-run-session")
        .args([
            "--",
            "sh",
            "-c",
            "eval \"$(printf 'scratch\\n' | gnome-keyring-daemon --unlock --components=secrets)\"; exec \"$@\"",
            "sh",
        ])
        .arg(exe)
        .args(["--exact", "the_login_keyring_in_that_session", "--ignored", "--nocapture", "--test-threads=1"])
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_else(|_| "/usr/bin".into()))
        .env("HOME", &home)
        .env("XDG_RUNTIME_DIR", &run)
        .env("LANG", "C.UTF-8")
        .env("NOVA_TEST_KEYRING_SESSION", &home)
        .output()
        .expect("dbus-run-session runs");
    let text =
        String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr);
    println!("{text}");
    let _ = fs::remove_dir_all(&scratch);
    assert!(
        out.status.success() && text.contains("1 passed") && !text.contains("FAIL"),
        "the keyring scenario failed"
    );
}

/// The keyring scenario itself, run by the test above and by nothing else:
/// anywhere else it does nothing, so that it never meets the user's keyring.
#[test]
#[ignore = "runs inside the previous test's D-Bus session"]
fn the_login_keyring_in_that_session() {
    let scratch_home = std::env::var("NOVA_TEST_KEYRING_SESSION").ok();
    if scratch_home.is_none() || std::env::var("HOME").ok() != scratch_home {
        println!("not in the keyring test's session: nothing done");
        return;
    }
    let pc = Pc::with_keyring("keyring");
    let server = Server::fake();
    server.make_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
    Phone::new(&server).put(
        "home",
        "a.ics",
        &vcal(&[&hour("a", "A", HOME_DAY[0], HOME_DAY[1])], ""),
    );
    pc.add(&server);
    let account = pc.account();
    let lookup = || {
        let out = Command::new("secret-tool")
            .args(["lookup", "service", "nova-calendar", "id", &account])
            .env_clear()
            .env("PATH", "/usr/bin")
            .env(
                "DBUS_SESSION_BUS_ADDRESS",
                std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap_or_default(),
            )
            .output()
            .expect("secret-tool runs");
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    pc.check(
        lookup() == server.password,
        "the password is in the login keyring, as it was typed",
    );
    pc.sync();
    pc.check(
        pc.items("Home").contains("a") && pc.status_of(&account).text("state") == "ok",
        "and read from it to sync",
    );
    pc.run(&["remove", &account], None);
    pc.check(
        lookup().is_empty(),
        "removing the account takes it out of the keyring",
    );
    server.stop();
}
