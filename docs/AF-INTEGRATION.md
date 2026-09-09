# Embedding YUKTI in AgentFoundry (AF)

Handoff spec for AF's coding-agent. Goal: ship YUKTI as a **built-in mobile
test-suite panel** inside the AF desktop IDE, so every AF developer can build,
review, and run device/simulator UI tests without leaving the IDE.

YUKTI is intentionally trivial to embed: **one stdlib-Python server + one
self-contained HTML page. Zero pip/npm dependencies.** No build step. It talks
to the host's Xcode Simulator / Android emulator through the `yukti` CLI.

---

## 1. What AF embeds

Two pieces, both already in this repo:

| Piece | Path | Role |
|---|---|---|
| **Studio server** | `studio/server.py` | stdlib `http.server`; serves the UI + a JSON/SSE API; shells out to the `yukti` CLI. Binds `127.0.0.1:$YUKTI_STUDIO_PORT` (default 8787). |
| **Studio UI** | `studio/index.html` | single page — flow list, live simulator view, build bar, run controls. Loaded in an AF webview/iframe. |
| **CLI** | `yukti` | bash; drives build/boot/install/launch + the deterministic flow engine ("Talos"). Studio never reimplements device logic — it calls this. |

**Recommended embed = process + webview.** AF spawns the Studio server as a
child process, then points an IDE panel (webview/iframe) at
`http://127.0.0.1:<port>/`. That's the whole integration. AF can optionally
build native panels against the HTTP API (§4) instead of the webview, but the
webview gives you the full tool for free.

---

## 2. Launch contract

AF spawns:

```
python3 <af-resources>/yukti/studio/server.py
```

with environment:

| Env var | Meaning | Default |
|---|---|---|
| `YUKTI_STUDIO_PORT` | port the panel binds | `8787` |
| `YUKTI_CONFIG` | path to the project's `yukti.config.json` (variants, projectRoot, workspace) | `<yukti>/yukti.config.json` |
| `YUKTI_FLOWS_DIR` | the project's flow suite (its test cases) | `<yukti>/flows` |
| `YUKTI_DEVICE_PT_W` / `_H` | device point size for click↔point mapping | `402` / `874` (iPhone 16 Pro) |
| `YUKTI_AI_CMD` | optional: command for the "AI Heal" seam (an agent that repairs a broken step). Leave unset to disable — no AI vendor is ever hardcoded. | unset |

For an AF workspace, set `YUKTI_CONFIG` and `YUKTI_FLOWS_DIR` to the open
project's files (e.g. `<project>/.yukti/xspan.config.json` and
`<project>/.yukti/flows`). Everything visual keys off those two.

Health check: `GET /api/health` → `200 {"status":"ok", ...}` once ready.
Shut down = kill the child process (it's stateless; creds live only in memory).

---

## 3. What the developer does in the panel (no terminal)

The UI already removed every export/CLI step:

- **Build bar** (top): pick a **variant** (from `yukti.config.json` — e.g.
  `dev`/`prod`), optionally type a **branch/tag** (e.g. `release/1.24.30`) to
  test any app version, enter **test creds**, and hit **⚙ Build & Launch**.
  This checks out the ref, builds a signed simulator app, boots the sim,
  installs, and launches — streamed live.
- **Test Cases** (left): every flow in `YUKTI_FLOWS_DIR`, with step counts.
  **▶ Run All** runs the whole suite; **loops=0** = continuous soak. Per-flow
  ✓/✗ + a pass/fail summary stream into the log.
- **Simulator view** (center): live screenshot; click-to-tap **record-and-replay**
  to author/repair a flow by clicking the real screen.
- **Editor** (right): the selected flow's steps, editable + saveable.

---

## 4. HTTP API (for native AF panels, optional)

All JSON unless noted. SSE = `text/event-stream`.

| Method / route | Purpose |
|---|---|
| `GET /api/health` | readiness + config paths |
| `GET /api/variants` | build variants, active variant, detected `app_version`, `creds_set` |
| `GET /api/flows` | list test cases (`file`, `name`, `steps`) |
| `GET /api/flow?name=` | one flow's JSON |
| `POST /api/flow` | save a flow |
| `GET /api/screen` | current simulator PNG (base64) |
| `GET /api/ui` | accessibility tree (JSON, points) |
| `POST /api/config` | set test creds + active variant (memory only) |
| `POST /api/up` *(SSE)* | build+boot+install+launch a variant; body `{variant, gitRef?}` |
| `POST /api/run` *(SSE)* | run one flow; body `{name}` |
| `POST /api/run-suite` *(SSE)* | run all flows; body `{loops, only?}`; `loops:0` = soak |
| `POST /api/tap` / `type` / `dismiss` | live drive primitives (record mode) |
| `POST /api/heal` *(SSE)* | AI-repair seam (only if `YUKTI_AI_CMD` set) |

SSE events: `log` (stream lines), `flow-start`/`flow-done` (suite progress),
`done` (final `{status, ...}`).

---

## 5. macOS desktop packaging notes

- **Python:** server is stdlib-only → any `python3` ≥ 3.8. Use the system
  `/usr/bin/python3`, or bundle a runtime. No `pip install` needed.
- **Host tools (not bundled — they live on the dev's Mac):** Xcode + a
  Simulator runtime, `idb` (`idb-companion` + `fb-idb`), `node@22`, `cocoapods`
  for iOS builds; `adb`/emulator for Android. Ship a **Doctor** action that runs
  `yukti doctor` and surfaces what's missing — don't try to bundle Xcode.
- **Signing / entitlements:** the Studio server only binds `127.0.0.1` and
  shells out to `yukti`. Under App Sandbox it needs permission to run child
  processes and reach localhost; if AF is sandboxed, run YUKTI in a helper /
  non-sandboxed XPC or relax the relevant entitlement. The *simulator app* YUKTI
  builds is ad-hoc signed (`CODE_SIGN_IDENTITY="-"`) by the CLI — that's a
  simulator artifact, unrelated to AF's own Developer ID signing/notarization.
- **Embeddability:** the server sets **no `X-Frame-Options`/CSP frame-ancestors**,
  so the page loads cleanly in an iframe/webview. Keep it bound to loopback.

---

## 6. License / provenance

MIT, open source: **github.com/karlmehta/yukti**. Vendor-neutral by design
(iOS + Android backends; the AI seam is a pluggable command, no model
hardcoded). Safe to ship as an AF built-in. The project-specific test suites
(a team's actual flows) stay in that team's own private repo and are pointed to
via `YUKTI_FLOWS_DIR` — they never live in the YUKTI package.
