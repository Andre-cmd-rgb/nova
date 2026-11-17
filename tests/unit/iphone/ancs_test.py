"""The ANCS half of nova-iphone-notifications, byte for byte as Apple's
specification lays it out: the events, the commands, the answers put back
together from fragments, and the texts made of them. Every fixture is built
here from the specification, none comes from a phone.

    python3 -B -I ancs_test.py <path to nova-iphone-notifications>
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import time
import unittest

PATH = sys.argv.pop(1)
loader = importlib.machinery.SourceFileLoader("daemon", PATH)
spec = importlib.util.spec_from_loader("daemon", loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)


def chunks(data, size):
    return [data[i:i + size] for i in range(0, len(data), size)]


class Events(unittest.TestCase):
    def test_an_event_is_eight_bytes_little_endian(self):
        # Added, Important + NegativeAction, Social, 3 in the category, UID 0x01020304.
        event = d.parse_event(bytes.fromhex("0012040304030201"))
        self.assertEqual(event, d.Event(d.ADDED, d.IMPORTANT | d.NEGATIVE_ACTION, d.SOCIAL, 3, 0x01020304))

    def test_each_flag(self):
        event = d.parse_event(bytes([d.MODIFIED, 0x1F, d.EMAIL, 1, 9, 0, 0, 0]))
        self.assertEqual(event.flags, d.SILENT | d.IMPORTANT | d.PRE_EXISTING | d.POSITIVE_ACTION | d.NEGATIVE_ACTION)
        self.assertEqual((event.kind, event.uid), (d.MODIFIED, 9))

    def test_malformed_events_are_none(self):
        self.assertIsNone(d.parse_event(b""))
        self.assertIsNone(d.parse_event(bytes(7)))
        self.assertIsNone(d.parse_event(bytes(9)))
        self.assertIsNone(d.parse_event(bytes([3, 0, 0, 0, 1, 0, 0, 0])))  # no EventID 3

    def test_the_specification_numbers(self):
        self.assertEqual((d.ADDED, d.MODIFIED, d.REMOVED), (0, 1, 2))
        self.assertEqual((d.SILENT, d.IMPORTANT, d.PRE_EXISTING, d.POSITIVE_ACTION, d.NEGATIVE_ACTION), (1, 2, 4, 8, 16))
        self.assertEqual((d.INCOMING_CALL, d.MISSED_CALL, d.SOCIAL, d.ENTERTAINMENT), (1, 2, 4, 11))
        self.assertEqual(d.ANCS_SERVICE, "7905f431-b5ce-4e99-a40f-4b1e122d00d0")
        self.assertEqual(d.NOTIFICATION_SOURCE, "9fbf120d-6301-42d9-8c58-25e699a21dbd")
        self.assertEqual(d.CONTROL_POINT, "69d1d8f3-45e1-49a8-9821-9bbdfdaad9d9")
        self.assertEqual(d.DATA_SOURCE, "22eac6e9-24d6-4bb5-be44-b36ace7c7bfb")


class Commands(unittest.TestCase):
    def test_get_notification_attributes(self):
        # CommandID 0, UID 5, then AppIdentifier; Title, Subtitle and
        # Message each with their most bytes, little-endian.
        command = d.notification_attributes_command(5, [d.APP_IDENTIFIER, d.TITLE, d.SUBTITLE, d.MESSAGE])
        self.assertEqual(command.hex(" "), "00 05 00 00 00 00 01 80 00 02 80 00 03 40 01")

    def test_the_date_has_no_length(self):
        command = d.notification_attributes_command(0xA1B2C3D4, [d.DATE])
        self.assertEqual(command.hex(" "), "00 d4 c3 b2 a1 05")

    def test_get_app_attributes(self):
        command = d.app_attributes_command(b"net.whatsapp.WhatsApp")
        self.assertEqual(command, b"\x01net.whatsapp.WhatsApp\x00\x00")

    def test_perform_notification_action(self):
        self.assertEqual(d.action_command(5, d.NEGATIVE).hex(" "), "02 05 00 00 00 01")
        self.assertEqual(d.action_command(0x01020304, d.POSITIVE).hex(" "), "02 04 03 02 01 00")


NOTE = (bytes.fromhex("0005000000")
        + bytes([0, 21, 0]) + b"net.whatsapp.WhatsApp"
        + bytes([1, 4, 0]) + b"Anna"
        + bytes([2, 0, 0])
        + bytes([3, 10, 0]) + b"Ciao <3 :)")
WANTED = [d.APP_IDENTIFIER, d.TITLE, d.SUBTITLE, d.MESSAGE]


class Answers(unittest.TestCase):
    def test_whole_in_one(self):
        found = d.Answer(NOTE[:5], WANTED).feed(NOTE)
        self.assertEqual(found, {0: b"net.whatsapp.WhatsApp", 1: b"Anna", 2: b"", 3: b"Ciao <3 :)"})

    def test_put_back_together_from_fragments_of_any_size(self):
        for size in (1, 2, 3, 7, 20, 23):
            answer = d.Answer(NOTE[:5], WANTED)
            results = [answer.feed(piece) for piece in chunks(NOTE, size)]
            self.assertTrue(all(r is None for r in results[:-1]), size)
            self.assertEqual(results[-1][3], b"Ciao <3 :)", size)

    def test_the_tail_of_an_answer_given_up_on_is_passed_over(self):
        answer = d.Answer(NOTE[:5], WANTED)
        self.assertIsNone(answer.feed(b"\x03\x05\x00tail!"))
        self.assertIsNone(answer.feed(NOTE[:3]))
        self.assertEqual(answer.feed(NOTE[3:])[1], b"Anna")

    def test_an_attribute_not_asked_for_does_not_fit(self):
        answer = d.Answer(NOTE[:5], [d.APP_IDENTIFIER])
        with self.assertRaises(ValueError):
            answer.feed(bytes.fromhex("0005000000") + bytes([1, 1, 0]) + b"x")

    def test_another_notification_answer_is_not_this_one(self):
        answer = d.Answer(bytes.fromhex("0006000000"), WANTED)
        self.assertIsNone(answer.feed(NOTE))

    def test_an_app_answer(self):
        command = d.app_attributes_command(b"com.apple.MobileSMS")
        reply = b"\x01com.apple.MobileSMS\x00" + bytes([0, 8, 0]) + b"Messages"
        answer = d.Answer(command[:-1], [d.DISPLAY_NAME])
        self.assertIsNone(answer.feed(reply[:10]))
        self.assertEqual(answer.feed(reply[10:]), {0: b"Messages"})


class Texts(unittest.TestCase):
    def test_plain_text(self):
        self.assertEqual(d.text(b"Hello  there\r\n\n\tyou\x00"), "Hello there\nyou")

    def test_cut_short_at_the_limit(self):
        raw = ("é" * 64).encode()[:127]  # 63 whole, then half of one
        self.assertEqual(len(raw), 127)
        self.assertEqual(d.text(raw, 127), "é" * 63 + "…")
        self.assertEqual(d.text(b"short", 128), "short")

    def test_emoji_sequences_stay_whole(self):
        joiner = chr(0x200D)
        family = "\U0001F468" + joiner + "\U0001F469" + joiner + "\U0001F467"
        self.assertEqual(d.text(family.encode()), family)

    def test_line_separators_become_lines(self):
        self.assertEqual(d.text(("one" + chr(0x2028) + "two" + chr(0x2029) + "three").encode()), "one\ntwo\nthree")

    def test_format_characters_go_but_the_joiners(self):
        # U+202E turns what follows around: "exe.txt" would read "txt.exe".
        spoof = "invoice" + chr(0x202E) + "txt.exe"
        self.assertEqual(d.text(spoof.encode()), "invoicetxt.exe")
        hidden = chr(0x2066) + "a" + chr(0x2069) + chr(0x200B) + "b" + chr(0xFEFF) + chr(0x00AD) + "c" + chr(0x200E)
        self.assertEqual(d.text(hidden.encode()), "abc")
        joined = "a" + chr(0x200C) + "b" + chr(0x200D) + "c"
        self.assertEqual(d.text(joined.encode()), joined)

    def test_more_than_the_limit_is_cut_here(self):
        # An iPhone keeps to the lengths asked for; text past them is cut all
        # the same, before it is decoded.
        self.assertEqual(d.text(b"A" * 5000, 128), "A" * 128 + "…")
        self.assertEqual(d.text(("é" * 3000).encode(), 128), "é" * 64 + "…")
        self.assertEqual(d.text((chr(0x202E) + "B" * 400).encode(), 320), "B" * 317 + "…")

    def test_names_are_one_line_and_short(self):
        self.assertEqual(d.name_text("Anna's\niPhone"), "Anna's iPhone")
        self.assertEqual(d.name_text(chr(0x202E) + "x" * 100), "x" * 61 + "…")
        self.assertEqual(d.name_text(b"WhatsApp"), "WhatsApp")
        self.assertEqual(d.name_text(None), "")

    def test_an_answer_longer_than_any_asked_for_does_not_fit(self):
        answer = d.Answer(NOTE[:5], WANTED)
        oversize = NOTE[:5] + bytes([0]) + (60000).to_bytes(2, "little")
        self.assertIsNone(answer.feed(oversize + b"x" * 4000))
        with self.assertRaises(ValueError):
            answer.feed(b"x" * 5000)

    def test_summary_and_body(self):
        self.assertEqual(d.toast_text("WhatsApp", "Anna", "", "Ciao <3 & more"),
                         ("WhatsApp · Anna", "Ciao &lt;3 &amp; more"))
        self.assertEqual(d.toast_text("Mail", "Amazon", "Your order", "Shipped"),
                         ("Mail · Amazon", "Your order\nShipped"))
        self.assertEqual(d.toast_text("Reminders", "Reminders", "", "Milk"), ("Reminders", "Milk"))
        self.assertEqual(d.toast_text("Clock", "", "", "Alarm"), ("Clock", "Alarm"))

    def test_an_app_with_no_name(self):
        self.assertEqual(d.app_fallback(b"net.whatsapp.WhatsApp"), "WhatsApp")
        self.assertEqual(d.app_fallback(b""), "iPhone")


class WhileAway(unittest.TestCase):
    def test_the_date(self):
        when = d.parse_date(b"20261117T143005")
        self.assertEqual(time.localtime(when)[:6], (2026, 11, 17, 14, 30, 5))
        self.assertIsNone(d.parse_date(b"yesterday"))
        self.assertIsNone(d.parse_date(b""))

    def test_only_what_came_after_the_link_dropped(self):
        dropped = d.parse_date(b"20261117T143000")
        now = dropped + 120
        self.assertTrue(d.arrived_while_away(b"20261117T143100", dropped, now))
        self.assertTrue(d.arrived_while_away(b"20261117T142930", dropped, now))  # a minute of clocks
        self.assertFalse(d.arrived_while_away(b"20261117T140000", dropped, now))
        self.assertFalse(d.arrived_while_away(b"20261118T143000", dropped, now))
        self.assertFalse(d.arrived_while_away(b"", dropped, now))


class LowEnergy(unittest.TestCase):
    def conf(self, text):
        with tempfile.NamedTemporaryFile("w", delete=False) as out:
            out.write(text)
        self.addCleanup(os.unlink, out.name)
        return out.name

    def test_as_bluez_reads_controller_mode(self):
        self.assertTrue(d.le_enabled(self.conf("[General]\n#ControllerMode = bredr\n")))
        self.assertFalse(d.le_enabled(self.conf("[General]\nControllerMode = bredr # classic only\n")))
        self.assertTrue(d.le_enabled(self.conf("[General]\nControllerMode = dual\n[LE]\nControllerMode = bredr\n")))
        self.assertTrue(d.le_enabled("/nonexistent/main.conf"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
