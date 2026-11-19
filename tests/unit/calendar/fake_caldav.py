# A CalDAV server small enough to read, for nova-calendar-sync's tests: what
# iCloud, Google and the others answer, as far as the sync asks it. On
# 127.0.0.1, in a thread of the test.
#
#   server = FakeCalDAV(user="alice", password="pw")      Basic auth
#   server = FakeCalDAV(bearer="token")                    Google's way
#   server.add_calendar("home", "Home", components=("VEVENT", "VTODO"))
#   server.start(); server.url; server.stop(); server.start() (the same port)
#
# Options a test turns: sync_tokens (WebDAV sync-collection, else only ctag
# and ETags), etag_on_put, home_url (the calendar home at an address of its
# own, as iCloud puts it on a partition), read_only on a calendar, moved
# ({path: address} redirected), unlisted (calendars the home's listing leaves
# out), elsewhere (addresses of calendars on another server it lists),
# withheld and vanished (items a calendar-multiget leaves out, or answers
# 404), delay ({path: seconds} before answering), feed_private (the feed
# asks for the password), trickle (seconds between the feed's bytes).
# Every request is in server.log as (method, path), and its Authorization
# header in server.auths.

import base64
import hashlib
import http.server
import json
import re
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET

DAV = "DAV:"
C = "urn:ietf:params:xml:ns:caldav"


def q(ns, name):
    return "{%s}%s" % (ns, name)


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Calendar:
    def __init__(self, name, display, components, color, read_only):
        self.name, self.display, self.components, self.color, self.read_only = name, display, components, color, read_only
        self.items = {}  # resource name -> (etag, text)
        self.log = []  # (seq, name), name deleted when not in items
        self.seq = 0
        self.ctag = 0


class FakeCalDAV:
    def __init__(self, user=None, password=None, bearer=None):
        self.user, self.password, self.bearer = user, password, bearer
        self.calendars = {}
        self.sync_tokens = True
        self.etag_on_put = True
        self.home_url = None
        self.moved = {}
        self.unlisted = set()
        self.elsewhere = []
        self.withheld = set()
        self.vanished = set()
        self.delay = {}
        self.feed_private = False
        self.trickle = 0
        self.log = []
        self.auths = []
        self.lock = threading.Lock()
        self.httpd = None
        self.port = 0
        self.etags = 0
        self.feed = None  # (etag, text) served at /feed.ics
        self.oauth = None  # Google's endpoints: {"code", "challenge", ...}

    # ---- set up and change, as the phone would
    def add_calendar(self, name, display, components=("VEVENT", "VTODO"), color="#FF2968FF", read_only=False):
        self.calendars[name] = Calendar(name, display, components, color, read_only)

    def put(self, cal, name, text):
        with self.lock:
            return self._store(self.calendars[cal], name, text)

    def remove(self, cal, name):
        with self.lock:
            c = self.calendars[cal]
            del c.items[name]
            self._changed(c, name)

    def item(self, cal, name):
        found = self.calendars[cal].items.get(name)
        return found[1] if found else None

    def find(self, cal, text):
        """The resources of a calendar with <text> in them."""
        return {n: t for n, (e, t) in self.calendars[cal].items.items() if text in t}

    def _store(self, c, name, text):
        self.etags += 1
        etag = '"e%d"' % self.etags
        c.items[name] = (etag, text)
        self._changed(c, name)
        return etag

    def _changed(self, c, name):
        c.seq += 1
        c.ctag += 1
        c.log.append((c.seq, name))

    # ---- running
    @property
    def url(self):
        return "http://127.0.0.1:%d/" % self.port

    def start(self):
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def handle_one(self):
                server.handle(self)

            do_GET = do_PUT = do_DELETE = do_PROPFIND = do_REPORT = do_POST = do_OPTIONS = handle_one

        http.server.ThreadingHTTPServer.allow_reuse_address = True
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    # ---- answering
    def handle(self, h):
        length = int(h.headers.get("Content-Length") or 0)
        body = h.rfile.read(length) if length else b""
        path = urllib.parse.urlsplit(h.path).path
        self.log.append((h.command, path))
        self.auths.append(h.headers.get("Authorization"))
        time.sleep(self.delay.get(path, 0))
        if path in self.moved:
            return self.reply(h, 307, b"", {"Location": self.moved[path]})
        if path == "/token" and h.command == "POST":
            return self.token(h, body)
        if path == "/auth" and self.oauth:
            return self.sign_in(h)
        if path == "/feed.ics" and not self.feed_private:
            return self.serve_feed(h)
        if not self.authorized(h):
            return self.reply(h, 401, b"", {"WWW-Authenticate": 'Basic realm="fake"'})
        if path == "/feed.ics":
            return self.serve_feed(h)
        if path == "/.well-known/caldav":
            return self.reply(h, 301, b"", {"Location": "/"})
        with self.lock:
            m = re.fullmatch(r"/alice/cals/([^/]+)/([^/]+)", path)
            if m and m.group(1) in self.calendars:
                return self.resource(h, self.calendars[m.group(1)], urllib.parse.unquote(m.group(2)), body)
            m = re.fullmatch(r"/alice/cals/([^/]+)/?", path)
            if m and m.group(1) in self.calendars:
                return self.collection(h, self.calendars[m.group(1)], body)
            if h.command == "PROPFIND":
                if path in ("/", "/alice/"):
                    return self.principal(h, path)
                if path == "/alice/cals/":
                    return self.home(h)
        return self.reply(h, 404, b"")

    def authorized(self, h):
        got = h.headers.get("Authorization", "")
        if self.bearer:
            return got == "Bearer " + self.bearer
        return got == "Basic " + base64.b64encode(("%s:%s" % (self.user, self.password)).encode()).decode()

    def reply(self, h, status, data, headers=None):
        h.send_response(status)
        for k, v in (headers or {}).items():
            h.send_header(k, v)
        h.send_header("Content-Length", str(len(data)))
        h.end_headers()
        h.wfile.write(data)

    def multistatus(self, h, responses, extra=""):
        xml = '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" ' \
              'xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/">%s%s</d:multistatus>' % ("".join(responses), extra)
        self.reply(h, 207, xml.encode(), {"Content-Type": "application/xml; charset=utf-8"})

    def response(self, href, props, missing=()):
        found = "<d:propstat><d:prop>%s</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>" % "".join(props)
        lost = "<d:propstat><d:prop>%s</d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>" % "".join(missing) if missing else ""
        return "<d:response><d:href>%s</d:href>%s%s</d:response>" % (esc(href), found, lost)

    def asked(self, body):
        try:
            root = ET.fromstring(body)
        except ET.ParseError:
            return set()
        prop = root.find(q(DAV, "prop"))
        return {p.tag for p in prop} if prop is not None else set()

    def principal(self, h, path):
        home = self.home_url or "/alice/cals/"
        props = ["<d:current-user-principal><d:href>/alice/</d:href></d:current-user-principal>"]
        if path == "/alice/":
            props.append("<c:calendar-home-set><d:href>%s</d:href></c:calendar-home-set>" % home)
        self.multistatus(h, [self.response(path, props)])

    def home(self, h):
        if h.headers.get("Depth") != "1":
            return self.multistatus(h, [self.response("/alice/cals/", ["<d:resourcetype><d:collection/></d:resourcetype>"])])
        out = [self.response("/alice/cals/", ["<d:resourcetype><d:collection/></d:resourcetype>"])]
        out.append(self.response("/alice/cals/inbox/", ["<d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>"]))
        for c in self.calendars.values():
            if c.name not in self.unlisted:
                out.append(self.response("/alice/cals/%s/" % c.name, self.calendar_props(c)))
        for href in self.elsewhere:
            out.append(self.response(href, ["<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>", "<d:displayname>Elsewhere</d:displayname>"]))
        self.multistatus(h, out)

    def calendar_props(self, c):
        privileges = "<d:privilege><d:read/></d:privilege>" + ("" if c.read_only else "<d:privilege><d:write/></d:privilege>")
        props = ["<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>", "<d:displayname>%s</d:displayname>" % esc(c.display),
                 "<a:calendar-color>%s</a:calendar-color>" % c.color,
                 "<c:supported-calendar-component-set>%s</c:supported-calendar-component-set>" % "".join('<c:comp name="%s"/>' % n for n in c.components),
                 "<d:current-user-privilege-set>%s</d:current-user-privilege-set>" % privileges, "<cs:getctag>c%d</cs:getctag>" % c.ctag]
        if self.sync_tokens:
            props.append("<d:sync-token>http://fake/sync/%d</d:sync-token>" % c.seq)
        return props

    def collection(self, h, c, body):
        base = "/alice/cals/%s/" % c.name
        if h.command == "PROPFIND":
            out = [self.response(base, self.calendar_props(c))]
            if h.headers.get("Depth") == "1":
                for name, (etag, _) in sorted(c.items.items()):
                    out.append(self.response(base + urllib.parse.quote(name), ["<d:getetag>%s</d:getetag>" % esc(etag), "<d:resourcetype/>"]))
            return self.multistatus(h, out)
        if h.command != "REPORT":
            return self.reply(h, 405, b"")
        root = ET.fromstring(body)
        if root.tag == q(DAV, "sync-collection"):
            if not self.sync_tokens:
                return self.reply(h, 403, b"")
            token = root.findtext(q(DAV, "sync-token")) or ""
            m = re.fullmatch(r"http://fake/sync/(\d+)", token)
            if token and not m:
                return self.reply(h, 403, b'<d:error xmlns:d="DAV:"><d:valid-sync-token/></d:error>')
            since = int(m.group(1)) if m else -1
            names = sorted({name for seq, name in c.log if seq > since}) if since >= 0 else sorted(c.items)
            out = []
            for name in names:
                href = base + urllib.parse.quote(name)
                if name in c.items:
                    out.append(self.response(href, ["<d:getetag>%s</d:getetag>" % esc(c.items[name][0])]))
                else:
                    out.append("<d:response><d:href>%s</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>" % esc(href))
            return self.multistatus(h, out, "<d:sync-token>http://fake/sync/%d</d:sync-token>" % c.seq)
        if root.tag == q(C, "calendar-multiget"):
            out = []
            for href in root.findall(q(DAV, "href")):
                name = urllib.parse.unquote(href.text.rsplit("/", 1)[-1])
                if name in self.withheld:
                    continue
                if name in c.items and name not in self.vanished:
                    etag, text = c.items[name]
                    out.append(self.response(href.text, ["<d:getetag>%s</d:getetag>" % esc(etag), "<c:calendar-data>%s</c:calendar-data>" % esc(text)]))
                else:
                    out.append("<d:response><d:href>%s</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>" % esc(href.text))
            return self.multistatus(h, out)
        return self.reply(h, 400, b"")

    def resource(self, h, c, name, body):
        current = c.items.get(name)
        if h.command == "GET":
            if not current:
                return self.reply(h, 404, b"")
            return self.reply(h, 200, current[1].encode(), {"ETag": current[0], "Content-Type": "text/calendar"})
        match, none = h.headers.get("If-Match"), h.headers.get("If-None-Match")
        if (match and (not current or current[0] != match)) or (none == "*" and current):
            return self.reply(h, 412, b"")
        if h.command == "PUT":
            if c.read_only:
                return self.reply(h, 403, b"")
            etag = self._store(c, name, body.decode())
            return self.reply(h, 204 if current else 201, b"", {"ETag": etag} if self.etag_on_put else {})
        if h.command == "DELETE":
            if c.read_only:
                return self.reply(h, 403, b"")
            if not current:
                return self.reply(h, 404, b"")
            del c.items[name]
            self._changed(c, name)
            return self.reply(h, 204, b"")
        return self.reply(h, 405, b"")

    def serve_feed(self, h):
        if not self.feed:
            return self.reply(h, 404, b"")
        etag, text = self.feed
        if h.headers.get("If-None-Match") == etag:
            return self.reply(h, 304, b"")
        if not self.trickle:
            return self.reply(h, 200, text.encode(), {"ETag": etag, "Content-Type": "text/calendar"})
        h.send_response(200)
        h.send_header("Content-Length", str(len(text.encode())))
        h.end_headers()
        try:
            for byte in text.encode():
                h.wfile.write(bytes([byte]))
                h.wfile.flush()
                time.sleep(self.trickle)
        except OSError:
            h.close_connection = True

    # Google's sign-in page, signed in at once: back to the app with a code.
    def sign_in(self, h):
        form = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlsplit(h.path).query).items()}
        self.oauth["challenge"] = form.get("code_challenge")
        back = form.get("redirect_uri", "") + "/?" + urllib.parse.urlencode({"code": self.oauth["code"], "state": form.get("state", "")})
        self.reply(h, 302, b"", {"Location": back})

    # Google's token endpoint: a code for the verifier its challenge was
    # made from, and a refresh token for a new access token.
    def token(self, h, body):
        form = {k: v[0] for k, v in urllib.parse.parse_qs(body.decode()).items()}
        o = self.oauth
        o.setdefault("requests", []).append(form)
        if form.get("client_id") != o["client_id"]:
            return self.reply(h, 401, b'{"error": "invalid_client"}')
        if form.get("grant_type") == "authorization_code":
            challenge = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).rstrip(b"=").decode()
            if form.get("code") != o["code"] or challenge != o.get("challenge"):
                return self.reply(h, 400, b'{"error": "invalid_grant"}')
            claims = base64.urlsafe_b64encode(json.dumps({"email": o["email"]}).encode()).rstrip(b"=").decode()
            answer = {"access_token": self.bearer, "expires_in": 3600, "refresh_token": o["refresh"], "id_token": "x.%s.y" % claims}
        elif form.get("grant_type") == "refresh_token":
            if form.get("refresh_token") != o["refresh"] or o.get("revoked"):
                return self.reply(h, 400, b'{"error": "invalid_grant"}')
            answer = {"access_token": self.bearer, "expires_in": 3600}
        else:
            return self.reply(h, 400, b'{"error": "unsupported_grant_type"}')
        self.reply(h, 200, json.dumps(answer).encode(), {"Content-Type": "application/json"})
