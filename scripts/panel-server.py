#!/usr/bin/env python3
"""Local panel server. Started only by panel.sh; standard library only."""
import argparse
import datetime
import hmac
import json
import os
import re
import secrets
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

OUTPUT_MAX = 4000
BODY_MAX = 16384
ACTION_TIMEOUT = 300
BOARD_TIMEOUT = 120
CLASS_RANK = {"auto": 0, "confirm": 1, "never": 2}
PLACEHOLDERS = ("{task_dir}", "{service}", "{verb}")
SCRIPT_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*\.sh$")
WORD = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# Which buttons apply depends on the hold state; ids absent here always apply.
APPLIES = {
    "hold-on": lambda t, g: t.get("hold_merge") != "yes",
    "hold-off": lambda t, g: t.get("hold_merge") == "yes",
    "hold-all-on": lambda t, g: not g,
    "hold-all-off": lambda t, g: g,
}


def stamp():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def frontmatter(path):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    if not lines or lines[0] != "---":
        return out
    for line in lines[1:]:
        if line == "---":
            break
        k, sep, v = line.partition(": ")
        if sep:
            out[k] = v
        elif line.endswith(":"):
            out[line[:-1]] = ""
    return out


class Panel:
    def __init__(self, a):
        self.data = a.data
        self.scripts = a.scripts
        self.page_path = a.page
        self.actions_path = a.actions
        self.idle = float(a.idle_min) * 60
        self.refresh = int(a.refresh_sec)
        with open(a.token_file, encoding="ascii") as f:
            self.token = f.read().strip()
        self.port = 0
        self.last_file = os.path.join(a.data, "panel", "last")
        self.last_request = time.monotonic()
        self.last_board = 0.0
        self.board_lock = threading.Lock()
        self.log_lock = threading.Lock()

    def touch(self):
        # Wall-clock seconds on disk: panel.sh reap reads them to stop a server that never exited by itself.
        self.last_request = time.monotonic()
        try:
            write_atomic(self.last_file, "%d\n" % int(time.time()))
        except OSError:
            pass

    def open_tasks(self):
        """Relative id -> (absolute dir, frontmatter) for every open task folder."""
        found = {}
        root = os.path.join(self.data, "tasks")
        try:
            scopes = sorted(os.listdir(root))
        except OSError:
            return found
        for s in scopes:
            sd = os.path.join(root, s)
            if not os.path.isdir(sd):
                continue
            for t in sorted(os.listdir(sd)):
                d = os.path.join(sd, t)
                fm = frontmatter(os.path.join(d, "task.md"))
                if fm.get("status") == "open":
                    found[s + "/" + t] = (d, fm)
        return found

    def services(self):
        """Service name -> {verb: class} read from DATA/services/<name>.conf; the panel= line too."""
        out = {}
        sd = os.path.join(self.data, "services")
        try:
            names = sorted(os.listdir(sd))
        except OSError:
            return out
        for n in names:
            if not n.endswith(".conf") or not WORD.match(n[:-5]):
                continue
            verbs, panel = {}, ""
            try:
                with open(os.path.join(sd, n), encoding="utf-8", errors="replace") as f:
                    for line in f.read().splitlines():
                        line = line.rstrip("\r")
                        m = re.match(r"^verb\.([A-Za-z0-9._-]+)=(auto|confirm):", line)
                        if m and m.group(1) not in verbs:
                            verbs[m.group(1)] = m.group(2)
                        elif line.startswith("panel=") and not panel:
                            panel = line[6:]
            except OSError:
                continue
            out[n[:-5]] = {"verbs": verbs, "panel": panel}
        return out

    def actions(self):
        rows = []
        try:
            with open(self.actions_path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            return rows
        seen = set()
        for line in lines:
            if not line or line.startswith("#"):
                continue
            c = line.split("\t")
            if len(c) != 5:
                continue
            aid, cls, scope, label, argv = c
            argv = argv.split()
            if (aid in seen or not WORD.match(aid) or cls not in CLASS_RANK or cls == "never"
                    or scope not in ("global", "task", "service") or not argv
                    or not SCRIPT_NAME.match(argv[0])):
                continue
            if any("{" in w and w not in PLACEHOLDERS for w in argv):
                continue
            seen.add(aid)
            rows.append({"id": aid, "class": cls, "scope": scope, "label": label, "argv": argv})
        return rows

    def hold_all(self):
        return os.path.exists(os.path.join(self.data, "tasks", "HOLD_MERGE"))

    def list_actions(self):
        tasks, svcs, g = self.open_tasks(), self.services(), self.hold_all()
        out = {"global": [], "tasks": [], "services": []}
        per_task = {k: [] for k in tasks}
        per_svc = {k: [] for k in svcs}
        for a in self.actions():
            if a["scope"] == "global":
                if APPLIES.get(a["id"], lambda t, g: True)({}, g):
                    out["global"].append(self.button(a, a["class"], {}))
            elif a["scope"] == "task":
                for k, (d, fm) in tasks.items():
                    if APPLIES.get(a["id"], lambda t, g: True)(fm, g):
                        per_task[k].append(self.button(a, a["class"], {"{task_dir}": k}))
            else:
                for name, s in svcs.items():
                    for verb, vcls in s["verbs"].items():
                        cls = max(a["class"], vcls, key=CLASS_RANK.get)
                        if cls != "never":
                            b = self.button(a, cls, {"{service}": name, "{verb}": verb})
                            b["verb"] = verb
                            per_svc[name].append(b)
        for k, (d, fm) in tasks.items():
            out["tasks"].append({"task": k, "dir": d, "actions": per_task[k]})
        for name, s in svcs.items():
            out["services"].append({"service": name, "panel": s["panel"], "actions": per_svc[name]})
        return out

    @staticmethod
    def button(a, cls, shown):
        words = [shown.get(w, w) for w in a["argv"]]
        label = a["label"].replace("{verb}", shown.get("{verb}", ""))
        return {"id": a["id"], "class": cls, "label": label, "command": " ".join(words)}

    def board(self, live):
        with self.board_lock:
            if time.monotonic() - self.last_board >= self.refresh or self.last_board == 0.0:
                argv = [os.path.join(self.scripts, "board.sh")] + (["--live"] if live else [])
                try:
                    subprocess.run(argv, cwd=self.scripts, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=BOARD_TIMEOUT)
                except (OSError, subprocess.TimeoutExpired):
                    pass
                self.last_board = time.monotonic()
            try:
                with open(os.path.join(self.data, "board.json"), "rb") as f:
                    return f.read()
            except OSError:
                return None

    def log(self, aid, target, code):
        line = "%s\t%s\t%s\t%s\n" % (stamp(), aid, target or "-", code)
        with self.log_lock:
            with open(os.path.join(self.data, "panel", "log"), "a", encoding="utf-8") as f:
                f.write(line)

    def run(self, req):
        """Returns (http status, answer dict)."""
        for k in ("id", "task", "service", "verb"):
            if not isinstance(req.get(k, ""), str):
                return 400, {"error": "%s must be a string" % k}
        if not isinstance(req.get("confirmed", False), bool):
            return 400, {"error": "confirmed must be true or false"}
        aid = req.get("id", "")
        a = next((x for x in self.actions() if x["id"] == aid), None)
        if a is None:
            return 404, {"error": "no such action"}
        cls, subst, target, task_dir = a["class"], {}, "", None
        if a["scope"] == "task":
            tasks = self.open_tasks()
            key = req.get("task", "")
            if key not in tasks:
                return 404, {"error": "not an open task folder"}
            task_dir = tasks[key][0]
            subst["{task_dir}"] = task_dir
            target = key
        elif a["scope"] == "service":
            name, verb = req.get("service", ""), req.get("verb", "")
            svcs = self.services()
            if name not in svcs:
                return 404, {"error": "no such service"}
            if verb not in svcs[name]["verbs"]:
                return 404, {"error": "the service binding lists no such verb"}
            cls = max(cls, svcs[name]["verbs"][verb], key=CLASS_RANK.get)
            subst["{service}"], subst["{verb}"] = name, verb
            target = name + " " + verb
        if cls == "never":
            return 404, {"error": "no such action"}
        if cls == "confirm" and req.get("confirmed") is not True:
            return 428, {"error": "needs confirmation", "confirm": True}
        argv = [subst.get(w, w) for w in a["argv"]]
        argv[0] = os.path.join(self.scripts, argv[0])
        if a["scope"] == "service" and cls == "confirm":
            argv.append("--confirmed")
        if not os.access(argv[0], os.X_OK):
            return 404, {"error": "the action's script is missing"}
        if a["argv"][0] == "panel.sh":
            return self.stop_later(a, argv, target)
        try:
            p = subprocess.run(argv, cwd=self.scripts, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=ACTION_TIMEOUT)
            code, out = p.returncode, p.stdout
        except subprocess.TimeoutExpired as e:
            code, out = 124, (e.output or b"") + b"\n(timed out)"
        except OSError:
            code, out = 127, b"could not start the action"
        self.log(aid, target, code)
        if task_dir:
            subprocess.run([os.path.join(self.scripts, "ledger.sh"), task_dir, "panel",
                            "button %s exit %d" % (aid, code)],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.last_board = 0.0
        text = out.decode("utf-8", "replace")
        if len(text) > OUTPUT_MAX:
            text = text[:OUTPUT_MAX] + "\n(cut)"
        return 200, {"exit": code, "output": text}

    def stop_later(self, a, argv, target):
        # panel.sh stop ends this process, so it runs detached after the answer has gone out.
        def later():
            time.sleep(0.3)
            subprocess.Popen(argv, cwd=self.scripts, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        self.log(a["id"], target, 0)
        threading.Thread(target=later, daemon=True).start()
        return 200, {"exit": 0, "output": "the panel is stopping"}


def make_handler(panel):
    class Handler(BaseHTTPRequestHandler):
        server_version = "panel"
        sys_version = ""

        def log_message(self, *args):
            pass

        def send(self, code, body, ctype="application/json", extra=None):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode("utf-8")
            elif isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Frame-Options", "DENY")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def refuse(self, code, why):
            self.send(code, {"error": why})

        def guard(self, api):
            """Returns True when the request may go on; otherwise it has been answered."""
            host = self.headers.get("Host", "")
            own = ("127.0.0.1:%d" % panel.port, "localhost:%d" % panel.port)
            if host not in own:
                self.refuse(403, "wrong Host")
                return False
            origin = self.headers.get("Origin")
            if origin is not None and origin != "http://" + host:
                self.refuse(403, "request from another site")
                return False
            site = self.headers.get("Sec-Fetch-Site")
            if site is not None and site not in ("same-origin", "none"):
                self.refuse(403, "request from another site; open the panel address directly")
                return False
            if api and not hmac.compare_digest(self.headers.get("X-Panel-Token", "").encode("utf-8"),
                                               panel.token.encode("utf-8")):
                self.refuse(403, "missing or wrong token")
                return False
            if not api and not hmac.compare_digest(self.key().encode("utf-8"), panel.token.encode("utf-8")):
                self.send(403, "This panel opens only from its full address, which carries a key.\n"
                               "Run scripts/panel.sh url to print it.\n", "text/plain; charset=utf-8")
                return False
            panel.touch()
            return True

        def key(self):
            values = parse_qs(urlsplit(self.path).query).get("key", [])
            return values[0] if len(values) == 1 else ""

        def do_GET(self):
            u = urlsplit(self.path)
            api = u.path.startswith("/api/")
            if not self.guard(api):
                return
            if u.path in ("/", "/index.html"):
                self.page()
            elif u.path == "/api/board":
                live = parse_qs(u.query).get("live", ["0"])[0] == "1"
                body = panel.board(live)
                if body is None:
                    self.refuse(503, "no board.json yet")
                else:
                    self.send(200, body)
            elif u.path == "/api/actions":
                self.send(200, panel.list_actions())
            else:
                self.refuse(404, "not found")

        def do_POST(self):
            u = urlsplit(self.path)
            if not self.guard(True):
                return
            if u.path != "/api/run":
                self.refuse(404, "not found")
                return
            ctype = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
            if ctype != "application/json":
                self.refuse(415, "the body must be application/json")
                return
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = -1
            if n < 0 or n > BODY_MAX:
                self.refuse(413, "body too large")
                return
            try:
                req = json.loads(self.rfile.read(n).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self.refuse(400, "the body is not JSON")
                return
            if not isinstance(req, dict):
                self.refuse(400, "the body must be a JSON object")
                return
            code, answer = panel.run(req)
            self.send(code, answer)

        def refuse_method(self):
            self.send(405, {"error": "method not allowed"}, extra={"Allow": "GET, POST"})

        do_OPTIONS = do_PUT = do_DELETE = do_PATCH = do_HEAD = refuse_method

        def page(self):
            try:
                with open(panel.page_path, encoding="utf-8") as f:
                    html = f.read()
            except OSError:
                self.refuse(500, "the page is missing")
                return
            nonce = secrets.token_urlsafe(16)
            frames = " ".join(sorted({s["panel"] for s in panel.services().values()
                                      if re.match(r"^https?://[^\s;,'\"]+$", s["panel"])}))
            csp = ("default-src 'none'; script-src 'nonce-%s'; style-src 'unsafe-inline'; connect-src 'self'; "
                   "img-src 'self' data:; frame-src %s; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
                   % (nonce, frames or "'none'"))
            html = (html.replace("__PANEL_TOKEN__", panel.token).replace("__PANEL_NONCE__", nonce)
                    .replace("__PANEL_REFRESH__", str(panel.refresh)))
            self.send(200, html, "text/html; charset=utf-8", {"Content-Security-Policy": csp})

    return Handler


def free_port(start):
    for port in range(start, min(start + 200, 65536)):
        listening = False
        for fam, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
            try:
                with socket.socket(fam, socket.SOCK_STREAM) as s:
                    s.settimeout(0.3)
                    if s.connect_ex((addr, port)) == 0:
                        listening = True
            except OSError:
                pass
        if listening:
            continue
        try:
            srv = Server(("127.0.0.1", port), None)
            return srv
        except OSError:
            continue
    return None


class Server(ThreadingHTTPServer):
    # Without this flag a BSD kernel lets a second socket bind a port another program listens on.
    allow_reuse_address = False
    daemon_threads = True

    def server_bind(self):
        # HTTPServer's own bind looks the host name up, which can hang for seconds without DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main():
    p = argparse.ArgumentParser()
    for k in ("data", "scripts", "page", "actions", "token-file", "port-from", "idle-min", "refresh-sec"):
        p.add_argument("--" + k, required=True)
    a = p.parse_args()
    os.umask(0o077)
    try:
        os.setsid()
    except OSError:
        pass
    panel = Panel(a)
    srv = free_port(int(a.port_from))
    if srv is None:
        print("no free port from %s" % a.port_from, file=sys.stderr)
        return 1
    srv.RequestHandlerClass = make_handler(panel)
    panel.port = srv.server_address[1]
    pdir = os.path.join(a.data, "panel")
    pid_file, port_file = os.path.join(pdir, "pid"), os.path.join(pdir, "port")
    write_atomic(pid_file, "%d\n" % os.getpid())
    write_atomic(port_file, "%d\n" % panel.port)
    panel.touch()

    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)

    def idle_watch():
        step = max(0.2, min(5.0, panel.idle / 4))
        while True:
            time.sleep(step)
            if time.monotonic() - panel.last_request > panel.idle:
                os.kill(os.getpid(), signal.SIGTERM)
                return
    threading.Thread(target=idle_watch, daemon=True).start()
    try:
        srv.serve_forever(poll_interval=0.2)
    except (SystemExit, KeyboardInterrupt):
        pass
    finally:
        srv.server_close()
        try:
            with open(pid_file, encoding="ascii") as f:
                mine = f.read().strip() == str(os.getpid())
        except OSError:
            mine = False
        if mine:
            for f in (pid_file, port_file, os.path.join(pdir, "token"), panel.last_file):
                try:
                    os.remove(f)
                except OSError:
                    pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
