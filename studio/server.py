#!/usr/bin/env python3
"""
YUKTI Studio — a dependency-light local web UI for the YUKTI mobile-QA CLI.

Single stdlib-only HTTP server (no Flask, no pip). It shells out to the `yukti`
CLI (absolute path, YUKTI_CONFIG passed through) and exposes a small JSON API plus
a static index.html so a non-CLI QA engineer can manage test cases, run them,
watch the simulator live, and record-and-replay flows.

Run:
    YUKTI_CONFIG=/path/to/example.config.json /usr/bin/python3 studio/server.py
    # then open http://localhost:8787/

Everything is stdlib: http.server + socketserver + subprocess + json.
Never uses shell=True with interpolation — every CLI call is a list argv.
"""

import base64
import json
import os
import re
import subprocess
import sys
import threading
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from http.server import HTTPServer
from urllib.parse import urlparse, parse_qs

# ── paths / config ───────────────────────────────────────────────────────────
STUDIO_DIR = os.path.dirname(os.path.abspath(__file__))
YUKTI_ROOT = os.path.dirname(STUDIO_DIR)                 # ~/workspace/yukti
YUKTI_BIN = os.path.join(YUKTI_ROOT, "yukti")           # the CLI, absolute
# Flows live in the yukti repo by default, but a project can point Studio at its
# own (private, git-ignored) flow suite without copying it into this public repo.
FLOWS_DIR = os.environ.get("YUKTI_FLOWS_DIR", os.path.join(YUKTI_ROOT, "flows"))
INDEX_HTML = os.path.join(STUDIO_DIR, "index.html")
PORT = int(os.environ.get("YUKTI_STUDIO_PORT", "8787"))

# YUKTI_CONFIG is passed through to every CLI call. Default mirrors the CLI's own
# default (./yukti.config.json relative to the yukti root).
YUKTI_CONFIG = os.environ.get(
    "YUKTI_CONFIG", os.path.join(YUKTI_ROOT, "yukti.config.json")
)

# AI self-heal seam: set YUKTI_AI_CMD to an agent command (e.g. a Claude Code /
# OpenAI computer-use wrapper) to enable /api/heal. Left unset by default — the
# endpoint returns {status:"not_configured"} so no AI vendor is ever hardcoded.
YUKTI_AI_CMD = os.environ.get("YUKTI_AI_CMD", "").strip()

# Device point size — screenshots come back as full-resolution PNGs; the frontend
# maps click pixels back to device points using this. iPhone 16 Pro = 402x874 pt.
# Overridable via env for other devices.
DEVICE_PT_W = int(os.environ.get("YUKTI_DEVICE_PT_W", "402"))
DEVICE_PT_H = int(os.environ.get("YUKTI_DEVICE_PT_H", "874"))
# Set explicitly, that pair is the answer for whatever device is attached. Left
# at its default it is an iOS answer, and only an iOS one: on Android the
# screenshot is in physical pixels and `adb shell input tap` takes the same
# pixels, so the basis is the PNG itself. A fixed iPhone pair used there records
# points no tap will land on, and nothing fails — the tap misses, the flow
# carries on, and the run breaks later on an assert about something else.
DEVICE_PT_FIXED = bool(
    os.environ.get("YUKTI_DEVICE_PT_W") or os.environ.get("YUKTI_DEVICE_PT_H")
)
# The basis of the last screenshot, so /api/health can answer by the same rule.
# (0, 0) is "no screenshot yet", which the frontend reads as "keep what I have".
LAST_PT = (0, 0)


# ── yukti CLI wrapper ────────────────────────────────────────────────────────
# Set visually from the Studio UI (no terminal exports): test creds + the active
# build variant. Merged into every CLI call's environment.
RUN_ENV = {}


def yukti_env():
    env = dict(os.environ)
    env["YUKTI_CONFIG"] = YUKTI_CONFIG
    env.update({k: v for k, v in RUN_ENV.items() if v})
    # Hand the child the answer instead of letting it reach one of its own. The
    # two agree on a variant that names its platform, and part on everything
    # else — a variant that names none, a config read from a different path, an
    # environment only one of them can see.
    p = run_platform()
    if p:
        env["YUKTI_PLATFORM"] = p
    return env


def platform_answer(variant=""):
    """Which platform this run drives, by the CLI's rules and in its words: the
    environment, then the platform of the variant in hand - the one picked in
    the panel, or a $YUKTI_VARIANT exported before Studio started, which the
    child inherits either way - then the config's top-level "platform".

    Returns (platform, source, conflict). Studio never worked this out at all:
    it passed the variant and let the child resolve on its own, so picking an
    Android variant in the UI still sent the run looking for a simulator.

    A variant that names its own platform states a fact about that variant, so
    an environment pinning a different one is not a preference to resolve. The
    CLI stops there, and a panel that answered anyway would show a platform
    while every call it makes dies on the contradiction. A conflict is
    therefore no platform at all, and it is reported in the words the CLI uses.
    An empty answer is "not known", never iOS.
    """
    env = (os.environ.get("YUKTI_PLATFORM") or "").strip()
    cfg = read_config()
    v = (variant or RUN_ENV.get("YUKTI_VARIANT") or os.environ.get("YUKTI_VARIANT") or "").strip()
    vp = ""
    if v:
        vp = str(((cfg.get("variants") or {}).get(v) or {}).get("platform") or "").strip()
    if env:
        if vp and vp != env:
            return "", "", (
                "$YUKTI_PLATFORM says %s and variant '%s' says %s - they cannot "
                "both be the platform of this run" % (env, v, vp)
            )
        return env, "$YUKTI_PLATFORM", ""
    if vp:
        return vp, "variant '%s'" % v, ""
    top = str(cfg.get("platform") or "").strip()
    if top:
        return top, '"platform" in %s' % YUKTI_CONFIG, ""
    return "", "", ""


def run_platform(variant=""):
    return platform_answer(variant)[0]


def point_basis(dims=(0, 0)):
    """What a click on the screenshot is converted against. On Android the PNG's
    own pixel size is the answer; on iOS the PNG is a 2x/3x raster and carries no
    point size, so the configured pair stands. YUKTI_DEVICE_PT_W/H set by hand
    win on both — that is the way out for a device this rule does not fit."""
    if DEVICE_PT_FIXED:
        return (DEVICE_PT_W, DEVICE_PT_H)
    plat = run_platform()
    if plat == "android":
        return (int(dims[0]), int(dims[1]))
    if plat == "ios":
        return (DEVICE_PT_W, DEVICE_PT_H)
    # No platform, so no basis. (0, 0) says that; the iPhone pair would have
    # claimed a device this panel has not established.
    return (0, 0)


def run_yukti(args, timeout=180):
    """Run `yukti <args...>` as a list argv (never shell=True). Returns
    (returncode, stdout_text, stderr_text). Never raises on CLI failure."""
    try:
        p = subprocess.run(
            [YUKTI_BIN] + list(args),
            cwd=YUKTI_ROOT,
            env=yukti_env(),
            capture_output=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode(
            "utf-8", "replace"
        )
    except subprocess.TimeoutExpired:
        return 124, "", "yukti call timed out after %ss" % timeout
    except FileNotFoundError:
        return 127, "", "yukti CLI not found at %s" % YUKTI_BIN
    except Exception as e:  # never crash the server on a CLI hiccup
        return 1, "", "yukti call failed: %s" % e


def run_yukti_binary(args, timeout=60):
    """Like run_yukti but returns raw stdout bytes (for screenshots)."""
    try:
        p = subprocess.run(
            [YUKTI_BIN] + list(args),
            cwd=YUKTI_ROOT,
            env=yukti_env(),
            capture_output=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")
    except Exception as e:
        return 1, b"", str(e)


def read_png_dimensions(path):
    """Read PNG width/height from the IHDR chunk. Stdlib only, no PIL."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
        if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        w = int.from_bytes(head[16:20], "big")
        h = int.from_bytes(head[20:24], "big")
        return w, h
    except Exception:
        return None


# ── screen tree (Inspect) ────────────────────────────────────────────────────
# `yukti ui` answers in the platform's own form: the uiautomator dump (XML) on
# Android, idb's describe-all (a JSON list) on iOS. The panel used to read only
# the second and swallow the error on the first, so on Android it showed an
# empty screen and blamed idb. The answer says what it is, so it is read by its
# form and not by the platform the panel believes it drives.
BOUNDS_RE = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def parse_tree(raw):
    """(units, nodes) from what `yukti ui` printed. Units are those of the
    boxes: "px" for a dump (screen pixels), "pt" for idb (points). Each node:
    i, parent, depth, id (what tapId compares), rid, text, desc, cls,
    bounds [x0, y0, x1, y1], clickable, enabled, scrollable. Anything that is
    neither form raises ValueError - the caller reports it, never drops it."""
    s = (raw or "").strip()
    if not s:
        return "", []
    if s.startswith("<"):
        return "px", _dump_nodes(s)
    if s.startswith("["):
        return "pt", _idb_nodes(s)
    raise ValueError("neither a uiautomator dump nor an idb tree: %r" % s[:80])


def _dump_nodes(text):
    # The dump comes from the device under test - our own emulator or phone.
    # expat resolves no external entities, so the stdlib parser is enough here.
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        raise ValueError("the uiautomator dump does not parse: %s" % e)
    nodes = []

    def walk(el, parent, depth):
        for ch in el:
            if ch.tag != "node":
                continue
            a = ch.attrib
            rid = a.get("resource-id", "")
            m = BOUNDS_RE.fullmatch(a.get("bounds", "").strip())
            i = len(nodes)
            nodes.append({
                "i": i, "parent": parent, "depth": depth,
                # com.app:id/email -> email, the segment tapId compares
                "id": rid.split("/")[-1], "rid": rid,
                "text": a.get("text", ""), "desc": a.get("content-desc", ""),
                "cls": a.get("class", ""),
                "bounds": [int(v) for v in m.groups()] if m else [0, 0, 0, 0],
                "clickable": a.get("clickable") == "true",
                "enabled": a.get("enabled") == "true",
                "scrollable": a.get("scrollable") == "true",
            })
            walk(ch, i, depth + 1)

    walk(root, None, 0)
    return nodes


def _idb_nodes(text):
    # idb gives a flat list: no nesting to show, every node at depth 0.
    try:
        tree = json.loads(text)
    except ValueError as e:
        raise ValueError("the idb tree does not parse: %s" % e)
    if not isinstance(tree, list):
        raise ValueError("the idb tree is not a list")
    nodes = []
    for e in tree:
        if not isinstance(e, dict):
            continue
        f = e.get("frame") or {}
        x0, y0 = f.get("x", 0) or 0, f.get("y", 0) or 0
        nodes.append({
            "i": len(nodes), "parent": None, "depth": 0,
            "id": str(e.get("AXUniqueId") or ""), "rid": "",
            "text": str(e.get("AXLabel") or ""), "desc": str(e.get("AXValue") or ""),
            "cls": str(e.get("type") or ""),
            "bounds": [x0, y0, x0 + (f.get("width", 0) or 0), y0 + (f.get("height", 0) or 0)],
            "clickable": None, "enabled": e.get("enabled"), "scrollable": None,
        })
    return nodes


def legacy_elements(nodes):
    """The list /api/ui gave before the inspector, kept for whoever reads it
    (docs/AF-INTEGRATION.md): one entry per node with a label, and its centre.
    The label is the text, else the content-desc (iOS: AXLabel, else AXValue)."""
    out = []
    for n in nodes:
        label = n["text"] or n["desc"]
        if not label:
            continue
        b = n["bounds"]
        out.append({"label": label, "type": n["cls"],
                    "x": int((b[0] + b[2]) / 2), "y": int((b[1] + b[3]) / 2)})
    return out


def pick_at(nodes, x, y):
    """The node under a point: of the boxes holding it (left/top edge in,
    right/bottom out, empty boxes never), the smallest; on a tie the deeper,
    then the later in the dump - the one drawn on top. None when no box holds
    it. index.html pickAt() is the same rule for hover; change both together."""
    best = None
    for n in nodes:
        x0, y0, x1, y1 = n["bounds"]
        if x1 <= x0 or y1 <= y0 or not (x0 <= x < x1 and y0 <= y < y1):
            continue
        key = ((x1 - x0) * (y1 - y0), -n["depth"], -n["i"])
        if best is None or key < best[0]:
            best = (key, n)
    return best[1] if best else None


def ui_answer(rc, out, err):
    """What /api/ui says about one `yukti ui` call. The old fields (elements,
    raw, ok) stay; outcome tells apart the three cases the old answer could
    not: not_read (with the reason), empty, ok."""
    raw = (out or "").strip()
    ans = {"raw": raw, "ok": rc == 0, "units": "", "nodes": [], "elements": []}
    if rc != 0:
        ans.update(outcome="not_read",
                   error=ANSI_RE.sub("", err or "").strip() or "yukti ui exited %d" % rc)
        return ans
    try:
        units, nodes = parse_tree(raw)
    except ValueError as e:
        ans.update(outcome="not_read", error=str(e))
        return ans
    ans.update(units=units, nodes=nodes, elements=legacy_elements(nodes),
               outcome="ok" if nodes else "empty")
    return ans


# ── flow file helpers ────────────────────────────────────────────────────────
def safe_flow_path(name):
    """Resolve a flow file name to an absolute path inside FLOWS_DIR only.
    Rejects traversal. Ensures a .json extension."""
    if "/" in name or "\\" in name or ".." in name:
        raise ValueError("invalid flow name")
    base = os.path.basename(name)
    if not base.endswith(".json"):
        base += ".json"
    full = os.path.normpath(os.path.join(FLOWS_DIR, base))
    if os.path.dirname(full) != os.path.normpath(FLOWS_DIR):
        raise ValueError("invalid flow name")
    return full


def list_flows():
    out = []
    try:
        for fn in sorted(os.listdir(FLOWS_DIR)):
            if not fn.endswith(".json"):
                continue
            full = os.path.join(FLOWS_DIR, fn)
            steps = 0
            display = fn[:-5]
            try:
                with open(full) as f:
                    data = json.load(f)
                steps = len(data.get("steps", []))
                display = data.get("name") or display
            except Exception:
                pass
            out.append({"file": fn, "name": display, "steps": steps})
    except FileNotFoundError:
        pass
    return out


def read_config():
    try:
        with open(YUKTI_CONFIG) as f:
            return json.load(f)
    except Exception:
        return {}


def list_variants():
    """Variant names + display info from the project's yukti config."""
    cfg = read_config()
    out = []
    # A variant that names no platform takes the config's top-level one, exactly
    # as the CLI does. It used to read "ios" here whatever the run would be, and
    # the panel showing one platform while the run drives another is the whole
    # subject of this endpoint.
    top = str(cfg.get("platform") or "").strip()
    for name, v in (cfg.get("variants") or {}).items():
        out.append({
            "name": name,
            "platform": str(v.get("platform") or top or "").strip(),
            "scheme": v.get("scheme", ""),
            "configuration": v.get("configuration", ""),
            "bundleId": v.get("bundleId") or v.get("package", ""),
        })
    return out


def app_version():
    """Best-effort current app version from the project's app.json / package.json."""
    cfg = read_config()
    root = cfg.get("projectRoot") or "."
    if not os.path.isabs(root):
        root = os.path.join(os.path.dirname(os.path.abspath(YUKTI_CONFIG)), root)
    for rel, path_keys in (
        ("app.json", (("expo", "version"), ("version",))),
        ("package.json", (("version",),)),
    ):
        try:
            with open(os.path.join(root, rel)) as f:
                data = json.load(f)
            for keys in path_keys:
                node = data
                for k in keys:
                    node = node.get(k) if isinstance(node, dict) else None
                if isinstance(node, str):
                    return {"version": node, "source": rel}
        except Exception:
            continue
    return {"version": None, "source": None}


# ── HTTP handler ─────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = "YuktiStudio/1.0"

    # keep the console quiet-ish
    def log_message(self, fmt, *args):
        sys.stderr.write("[studio] %s\n" % (fmt % args))

    # -- response helpers --
    def _json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _text(self, text, status=200, ctype="text/plain; charset=utf-8"):
        body = text.encode("utf-8") if isinstance(text, str) else text
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    # -- routing --
    def do_GET(self):
        parsed = urlparse(self.path)
        route = parsed.path
        qs = parse_qs(parsed.query)
        try:
            if route == "/" or route == "/index.html":
                return self._serve_index()
            if route == "/api/health":
                plat, plat_src, plat_conflict = platform_answer()
                return self._json(
                    {
                        "status": "ok",
                        "config": YUKTI_CONFIG,
                        "yukti_bin": YUKTI_BIN,
                        "device_pt": list(point_basis(LAST_PT)),
                        "platform": plat,
                        "platform_source": plat_src,
                        "platform_conflict": plat_conflict,
                        "ai_configured": bool(YUKTI_AI_CMD),
                    }
                )
            if route == "/api/flows":
                return self._json({"flows": list_flows()})
            if route == "/api/variants":
                return self._json({
                    "variants": list_variants(),
                    "active": RUN_ENV.get("YUKTI_VARIANT", ""),
                    "app_version": app_version(),
                    "creds_set": bool(RUN_ENV.get("TEST_EMAIL")),
                })
            if route == "/api/flow":
                return self._get_flow(qs)
            if route == "/api/screen":
                return self._get_screen()
            if route == "/api/ui":
                return self._get_ui()
            if route == "/api/inspect":
                return self._get_inspect()
            return self._json({"error": "not found", "path": route}, 404)
        except Exception as e:
            return self._json({"error": str(e)}, 500)

    def do_POST(self):
        route = urlparse(self.path).path
        try:
            if route == "/api/flow":
                return self._save_flow()
            if route == "/api/run":
                return self._run_flow()
            if route == "/api/run-suite":
                return self._run_suite()
            if route == "/api/config":
                return self._set_config()
            if route == "/api/up":
                return self._up()
            if route == "/api/tap":
                return self._tap()
            if route == "/api/type":
                return self._type()
            if route == "/api/dismiss":
                return self._dismiss()
            if route == "/api/heal":
                return self._heal()
            return self._json({"error": "not found", "path": route}, 404)
        except Exception as e:
            return self._json({"error": str(e)}, 500)

    # -- handlers --
    def _serve_index(self):
        try:
            with open(INDEX_HTML, "rb") as f:
                self._text(f.read(), ctype="text/html; charset=utf-8")
        except FileNotFoundError:
            self._text("index.html missing", 500)

    def _get_flow(self, qs):
        name = (qs.get("name") or [""])[0]
        if not name:
            return self._json({"error": "name required"}, 400)
        try:
            path = safe_flow_path(name)
        except ValueError as e:
            return self._json({"error": str(e)}, 400)
        if not os.path.exists(path):
            return self._json({"error": "flow not found"}, 404)
        with open(path) as f:
            try:
                data = json.load(f)
            except Exception as e:
                return self._json({"error": "invalid flow json: %s" % e}, 500)
        return self._json(data)

    def _save_flow(self):
        body = self._read_body()
        name = (body.get("name") or "").strip()
        steps = body.get("steps")
        if not name:
            return self._json({"error": "name required"}, 400)
        if not isinstance(steps, list):
            return self._json({"error": "steps must be a list"}, 400)
        try:
            path = safe_flow_path(name)
        except ValueError as e:
            return self._json({"error": str(e)}, 400)
        # Preserve a human display name inside the file (the CLI reads "name"/"steps").
        display = body.get("displayName") or name
        doc = {"name": display, "steps": steps}
        if body.get("note"):
            doc["note"] = body["note"]
        os.makedirs(FLOWS_DIR, exist_ok=True)
        with open(path, "w") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
        return self._json({"status": "saved", "file": os.path.basename(path)})

    def _get_screen(self):
        # yukti shot writes a PNG and echoes its path on stdout.
        rc, out, err = run_yukti_binary(["shot"], timeout=45)
        path = out.decode("utf-8", "replace").strip() if isinstance(out, bytes) else ""
        # `shot` prints the path (its own stdout is text); read the PNG file.
        if rc != 0 or not path or not os.path.exists(path):
            # graceful fallback: 1x1 transparent PNG + status header
            png = (
                b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00"
                b"\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc"
                b"\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
            )
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("X-Yukti-Screen", "unavailable")
            self.send_header("Content-Length", str(len(png)))
            self.end_headers()
            self.wfile.write(png)
            return
        with open(path, "rb") as f:
            png = f.read()
        dims = read_png_dimensions(path) or (0, 0)
        pt = point_basis(dims)
        global LAST_PT
        LAST_PT = pt
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("X-Yukti-Screen", "ok")
        self.send_header("X-Yukti-Png-W", str(dims[0]))
        self.send_header("X-Yukti-Png-H", str(dims[1]))
        self.send_header("X-Yukti-Pt-W", str(pt[0]))
        self.send_header("X-Yukti-Pt-H", str(pt[1]))
        self.send_header("Content-Length", str(len(png)))
        self.end_headers()
        self.wfile.write(png)

    def _get_ui(self):
        return self._json(ui_answer(*run_yukti(["ui"], timeout=45)))

    def _get_inspect(self):
        # The screenshot and the tree as one pair, taken one after the other,
        # as uiautomatorviewer does: the boxes are drawn over this picture, not
        # over whatever the 1 s screen poll shows next. Its own file name, so a
        # poll still in flight cannot overwrite the picture between shot and read.
        rc, out, err = run_yukti_binary(["shot", "studio-inspect.png"], timeout=45)
        path = out.decode("utf-8", "replace").strip() if isinstance(out, bytes) else ""
        if rc != 0 or not path or not os.path.exists(path):
            return self._json({
                "outcome": "not_read", "units": "", "nodes": [], "elements": [],
                "error": ANSI_RE.sub("", err or "").strip()
                or "no screenshot (yukti shot exited %d)" % rc,
            })
        with open(path, "rb") as f:
            png = f.read()
        dims = read_png_dimensions(path) or (0, 0)
        pt = point_basis(dims)
        global LAST_PT
        LAST_PT = pt
        ans = ui_answer(*run_yukti(["ui"], timeout=45))
        ans.pop("raw", None)
        ans.update(png=base64.b64encode(png).decode("ascii"),
                   png_w=dims[0], png_h=dims[1], pt_w=pt[0], pt_h=pt[1])
        return self._json(ans)

    def _run_flow(self):
        """Run `yukti flow <file>` and stream stdout live via SSE."""
        body = self._read_body()
        name = (body.get("name") or "").strip()
        if not name:
            return self._json({"error": "name required"}, 400)
        try:
            path = safe_flow_path(name)
        except ValueError as e:
            return self._json({"error": str(e)}, 400)
        if not os.path.exists(path):
            return self._json({"error": "flow not found"}, 404)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(event, data):
            try:
                self.wfile.write(("event: %s\n" % event).encode("utf-8"))
                for line in str(data).splitlines() or [""]:
                    self.wfile.write(("data: %s\n" % line).encode("utf-8"))
                self.wfile.write(b"\n")
                self.wfile.flush()
            except Exception:
                pass

        emit("log", "▸ running flow: %s" % os.path.basename(path))
        try:
            proc = subprocess.Popen(
                [YUKTI_BIN, "flow", path],
                cwd=YUKTI_ROOT,
                env=yukti_env(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                universal_newlines=True,
            )
        except Exception as e:
            emit("done", json.dumps({"status": "error", "error": str(e)}))
            return
        for line in iter(proc.stdout.readline, ""):
            emit("log", line.rstrip("\n"))
        proc.stdout.close()
        rc = proc.wait()
        emit(
            "done",
            json.dumps({"status": "passed" if rc == 0 else "failed", "code": rc}),
        )

    def _run_suite(self):
        """Run every flow in FLOWS_DIR in order and stream results via SSE.

        Body (all optional):
          loops: int   — repeat the whole suite N times (default 1; use for a
                          continuous soak run). 0 or negative = run until the
                          client disconnects.
          only:  [str] — restrict to these flow filenames (default: all).
        Parallel across flows needs multiple booted simulators (one screen can
        only run one flow at a time); shard the suite across sims by launching
        one Studio per sim with YUKTI_FLOWS_DIR pointed at a per-shard subset.
        """
        body = self._read_body()
        loops = int(body.get("loops", 1) or 1)
        only = body.get("only") or None
        flows = [f["file"] for f in list_flows()]
        if only:
            only_set = set(only)
            flows = [f for f in flows if f in only_set]

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(event, data):
            try:
                self.wfile.write(("event: %s\n" % event).encode("utf-8"))
                for line in str(data).splitlines() or [""]:
                    self.wfile.write(("data: %s\n" % line).encode("utf-8"))
                self.wfile.write(b"\n")
                self.wfile.flush()
                return True
            except Exception:
                return False

        emit("log", "▸ suite: %d flow(s) × %s loop(s)"
             % (len(flows), "∞" if loops <= 0 else loops))
        results = []
        loop_i = 0
        try:
            while loops <= 0 or loop_i < loops:
                loop_i += 1
                emit("log", "── loop %d ──" % loop_i)
                for fn in flows:
                    path = os.path.join(FLOWS_DIR, fn)
                    emit("flow-start", json.dumps({"file": fn, "loop": loop_i}))
                    try:
                        proc = subprocess.Popen(
                            [YUKTI_BIN, "flow", path],
                            cwd=YUKTI_ROOT, env=yukti_env(),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            bufsize=1, universal_newlines=True,
                        )
                    except Exception as e:
                        emit("flow-done", json.dumps(
                            {"file": fn, "status": "error", "error": str(e)}))
                        results.append((fn, "error"))
                        continue
                    for line in iter(proc.stdout.readline, ""):
                        if not emit("log", line.rstrip("\n")):
                            proc.kill()
                            return  # client disconnected — stop the soak
                    proc.stdout.close()
                    rc = proc.wait()
                    status = "passed" if rc == 0 else "failed"
                    results.append((fn, status))
                    emit("flow-done", json.dumps(
                        {"file": fn, "status": status, "code": rc}))
        finally:
            passed = sum(1 for _, s in results if s == "passed")
            failed = sum(1 for _, s in results if s != "passed")
            emit("done", json.dumps({
                "status": "passed" if failed == 0 else "failed",
                "total": len(results), "passed": passed, "failed": failed,
                "loops": loop_i,
                "failures": [f for f, s in results if s != "passed"],
            }))

    def _set_config(self):
        """Store test creds + active variant visually (no terminal exports).
        Body: {testEmail, testPassword, variant}. Creds stay in server memory
        (localhost only) — never written to disk."""
        body = self._read_body()
        if "testEmail" in body:
            RUN_ENV["TEST_EMAIL"] = (body.get("testEmail") or "").strip()
        if "testPassword" in body:
            RUN_ENV["TEST_PASSWORD"] = body.get("testPassword") or ""
        if "variant" in body:
            RUN_ENV["YUKTI_VARIANT"] = (body.get("variant") or "").strip()
        return self._json({
            "ok": True,
            "active": RUN_ENV.get("YUKTI_VARIANT", ""),
            "creds_set": bool(RUN_ENV.get("TEST_EMAIL")),
        })

    def _up(self):
        """Build + boot + install + launch a variant, streaming logs via SSE.
        Body: {variant, gitRef?}. gitRef (branch/tag, e.g. release/1.24.30) is
        checked out in the project root first so any app version can be tested
        from the UI. This is the visual replacement for `yukti up <variant>`."""
        body = self._read_body()
        variant = (body.get("variant") or RUN_ENV.get("YUKTI_VARIANT") or "").strip()
        git_ref = (body.get("gitRef") or "").strip()
        if not variant:
            return self._json({"error": "variant required"}, 400)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(event, data):
            try:
                self.wfile.write(("event: %s\n" % event).encode("utf-8"))
                for line in str(data).splitlines() or [""]:
                    self.wfile.write(("data: %s\n" % line).encode("utf-8"))
                self.wfile.write(b"\n")
                self.wfile.flush()
            except Exception:
                pass

        # Optional: check out a specific app version (branch/tag) before building.
        if git_ref:
            cfg = read_config()
            root = cfg.get("projectRoot") or "."
            if not os.path.isabs(root):
                root = os.path.join(os.path.dirname(os.path.abspath(YUKTI_CONFIG)), root)
            emit("log", "▸ git checkout %s  (in %s)" % (git_ref, root))
            try:
                p = subprocess.run(["git", "-C", root, "checkout", git_ref],
                                   capture_output=True, text=True, timeout=60)
                emit("log", (p.stdout + p.stderr).strip())
                if p.returncode != 0:
                    emit("done", json.dumps({"status": "failed", "step": "checkout"}))
                    return
            except Exception as e:
                emit("done", json.dumps({"status": "error", "error": str(e)}))
                return

        RUN_ENV["YUKTI_VARIANT"] = variant
        emit("log", "▸ yukti up %s  (build + boot + install + launch)" % variant)
        try:
            proc = subprocess.Popen(
                [YUKTI_BIN, "up", variant],
                cwd=YUKTI_ROOT, env=yukti_env(),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                bufsize=1, universal_newlines=True,
            )
        except Exception as e:
            emit("done", json.dumps({"status": "error", "error": str(e)}))
            return
        for line in iter(proc.stdout.readline, ""):
            emit("log", line.rstrip("\n"))
        proc.stdout.close()
        rc = proc.wait()
        emit("done", json.dumps({
            "status": "passed" if rc == 0 else "failed",
            "code": rc, "variant": variant,
            "app_version": app_version(),
        }))

    def _tap(self):
        body = self._read_body()
        try:
            x = int(round(float(body["x"])))
            y = int(round(float(body["y"])))
        except (KeyError, ValueError, TypeError):
            return self._json({"error": "x and y (numbers) required"}, 400)
        rc, out, err = run_yukti(["tap", str(x), str(y)], timeout=30)
        return self._json(
            {"status": "ok" if rc == 0 else "error", "x": x, "y": y,
             "stdout": out, "stderr": err},
            200 if rc == 0 else 500,
        )

    def _type(self):
        body = self._read_body()
        text = body.get("text")
        if text is None:
            return self._json({"error": "text required"}, 400)
        rc, out, err = run_yukti(["type", str(text)], timeout=120)
        return self._json(
            {"status": "ok" if rc == 0 else "error", "stdout": out, "stderr": err},
            200 if rc == 0 else 500,
        )

    def _dismiss(self):
        rc, out, err = run_yukti(["dismiss"], timeout=45)
        return self._json(
            {"status": "ok" if rc == 0 else "error", "stdout": out, "stderr": err},
            200 if rc == 0 else 500,
        )

    def _heal(self):
        """AI self-heal HOOK (pluggable AI-fallback seam).

        Vendor-neutral by design. If YUKTI_AI_CMD is set, we invoke it as an argv
        list with the goal as the final arg and pass the current UI tree on stdin,
        so any computer-use agent (Claude Code, OpenAI, or your own) can drive the
        yukti primitives to recover a stuck flow. If unset, we return
        not_configured so no AI vendor is ever hardcoded here.
        """
        body = self._read_body()
        goal = (body.get("goal") or "").strip()
        if not YUKTI_AI_CMD:
            return self._json(
                {
                    "status": "not_configured",
                    "hint": "set YUKTI_AI_CMD to an agent command (e.g. a Claude "
                    "Code or OpenAI computer-use wrapper) to enable AI self-heal",
                }
            )
        # UI context for the agent (best-effort).
        _, ui_out, _ = run_yukti(["ui"], timeout=30)
        try:
            proc = subprocess.run(
                YUKTI_AI_CMD.split() + [goal],
                cwd=YUKTI_ROOT,
                env=yukti_env(),
                input=ui_out,
                capture_output=True,
                text=True,
                timeout=300,
            )
            return self._json(
                {
                    "status": "ok" if proc.returncode == 0 else "error",
                    "goal": goal,
                    "stdout": proc.stdout,
                    "stderr": proc.stderr,
                    "code": proc.returncode,
                }
            )
        except Exception as e:
            return self._json({"status": "error", "error": str(e)}, 500)


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    if not os.path.exists(YUKTI_BIN):
        sys.stderr.write("WARNING: yukti CLI not found at %s\n" % YUKTI_BIN)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("YUKTI Studio → http://localhost:%d/" % PORT)
    print("  config : %s" % YUKTI_CONFIG)
    print("  yukti  : %s" % YUKTI_BIN)
    # The banner used to state an iPhone basis whatever the run was. Say which
    # platform this panel resolved and what a recorded tap will be written
    # against, so a wrong variant shows here rather than in a flow of misses.
    plat, plat_src, plat_conflict = platform_answer()
    if plat_conflict:
        print("  platform: %s" % plat_conflict)
    else:
        print("  platform: %s" % ("%s (from %s)" % (plat, plat_src) if plat
                                  else "not resolved yet - pick a variant in the panel"))
    if DEVICE_PT_FIXED or plat == "ios":
        basis = "%dx%d pt" % (DEVICE_PT_W, DEVICE_PT_H)
    elif not plat:
        basis = "not known until the platform is"
    else:
        basis = "the screenshot's own pixels"
    print("  device : %s   AI-heal: %s"
          % (basis, "configured" if YUKTI_AI_CMD else "off"))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")
        srv.shutdown()


if __name__ == "__main__":
    main()
