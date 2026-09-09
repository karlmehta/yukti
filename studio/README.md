# YUKTI Studio

A dependency-light **local web dashboard** that wraps the [`yukti`](../yukti) mobile-QA
CLI so a non-CLI QA engineer can manage test cases, run them, **watch the simulator
live**, and **record-and-replay** flows — all in the browser.

- **One file server**, stdlib only. No Flask, no pip, no build step. Runs on
  `/usr/bin/python3`.
- Shells out to the `yukti` CLI via `subprocess` (list argv — never `shell=True`
  with interpolation), passing `YUKTI_CONFIG` straight through.
- **Frontend** is a single `index.html` (vanilla HTML/CSS/JS).

```
studio/
  server.py     # stdlib HTTP server + JSON API + yukti subprocess wrapper
  index.html    # the dashboard (served at /)
  README.md     # this file
```

## Launch

```bash
YUKTI_CONFIG=~/workspace/yukti/examples/example.config.json \
  /usr/bin/python3 ~/workspace/yukti/studio/server.py
# → http://localhost:8787/
```

Have a simulator running first (so screenshots/taps work):

```bash
YUKTI_CONFIG=~/workspace/yukti/examples/example.config.json yukti up dev
```

Environment knobs (all optional):

| Env | Default | Purpose |
| --- | --- | --- |
| `YUKTI_CONFIG` | `<repo>/yukti.config.json` | passed to every CLI call |
| `YUKTI_STUDIO_PORT` | `8787` | listen port (binds `127.0.0.1` only) |
| `YUKTI_DEVICE_PT_W` / `YUKTI_DEVICE_PT_H` | `402` / `874` | device point size (iPhone 16 Pro). Used to map screenshot clicks → device tap points |
| `YUKTI_AI_CMD` | *(unset)* | AI self-heal agent command — see below |

## Layout

- **Left — Test Cases**: every `flows/*.json`, with **Run** and **Edit**.
- **Center — Simulator**: a live screenshot (polled ~1s via `yukti shot`). In
  **record mode**, clicking the image taps the device. Below it: a run/record log
  (Run streams live over SSE, showing PASS/FAIL) plus a type box, Refresh, Show
  Elements (accessibility tree), Dismiss modals, and AI Heal.
- **Right — Flow Editor**: the step list (reorder ↑/↓, delete ✕), quick-add
  buttons, and **Save Flow**.

## Record-and-replay

1. Name the flow in the editor (right), or hit **+ New / Record Flow**.
2. Click **● Start Recording**.
3. **Click on the simulator** where you want to tap. The click pixel is mapped
   back to **device points** — the server reads the actual PNG dimensions from
   `yukti shot` and scales by the device point size (402×874 for iPhone 16 Pro),
   fires `yukti tap x y`, and appends a `{"do":"tap","x":…,"y":…}` step.
4. Type into the **type box** and press Type (or Enter) to fire `yukti type` and
   append a `{"do":"type","value":…}` step.
5. Use **Add wait / screenshot / dismiss / assertText / tapText** for the
   non-tap steps.
6. Click **■ Stop Recording**, then **Save Flow** → writes
   `flows/<name>.json` in the exact schema the Talos engine runs.
7. **Replay**: hit **Run** on that flow in the left column. Output streams live;
   the badge shows PASS/FAIL.

Saved files match the CLI flow schema (`{"name","steps":[…]}`) so they are also
runnable headless / in CI with `yukti flow flows/<name>.json`.

## AI self-heal hook (pluggable, vendor-neutral)

`POST /api/heal {goal}` is the **AI-fallback seam** for when a deterministic flow
gets stuck (an unexpected modal, a moved button). It is intentionally **not wired
to any AI vendor**.

- **Unconfigured (default):** returns
  `{"status":"not_configured","hint":"set YUKTI_AI_CMD to an agent command"}`.
- **Configured:** set `YUKTI_AI_CMD` to any computer-use agent command (Claude
  Code, OpenAI, or your own). The server invokes it as
  `<YUKTI_AI_CMD> "<goal>"` with the current `yukti ui` accessibility tree piped
  to **stdin**, and `YUKTI_CONFIG` in its env, so the agent can *see* (`yukti
  shot` / `yukti ui`) and *act* (`yukti tap` / `yukti type` / `yukti find`) to
  recover — the same primitives the CLI already exposes.

```bash
# example: a wrapper you write that drives the yukti primitives toward a goal
export YUKTI_AI_CMD="python3 my_agent.py --heal"
```

This keeps the model-agnostic contract from the CLI (“YUKTI just exposes *see*
and *act*”) intact — swap agents by changing one env var, no code edits.

## API

| Method / path | Does |
| --- | --- |
| `GET /` | the dashboard |
| `GET /api/health` | config path, device pt size, AI-configured flag |
| `GET /api/flows` | `[{file,name,steps}]` |
| `GET /api/flow?name=X` | the flow JSON |
| `POST /api/flow` `{name,steps}` | save/create `flows/<name>.json` |
| `GET /api/screen` | live PNG (`yukti shot`), no-cache; PNG + device pt sizes in `X-Yukti-*` headers |
| `GET /api/ui` | parsed accessibility tree (`yukti ui`) |
| `POST /api/run` `{name}` | `yukti flow` streamed over SSE; PASS/FAIL |
| `POST /api/tap` `{x,y}` | `yukti tap x y` |
| `POST /api/type` `{text}` | `yukti type "text"` |
| `POST /api/dismiss` | `yukti dismiss` |
| `POST /api/heal` `{goal}` | AI self-heal hook (see above) |

## Robustness / limitations

- Missing screenshot is handled gracefully — `/api/screen` returns a 1×1
  transparent PNG with `X-Yukti-Screen: unavailable` instead of erroring, and the
  UI shows *“no simulator — run `yukti up`.”*
- Every CLI shell-out uses **list argv** (no shell interpolation) and never
  crashes the server on failure — errors come back as JSON.
- Flow file names are sandboxed to `flows/` (path-traversal rejected).
- Binds `127.0.0.1` only — local-use tool, no auth.
- Click→point mapping assumes a single non-rotated portrait device; landscape or
  a device whose point size differs from the `YUKTI_DEVICE_PT_*` env will need
  those envs set.
- One simulator at a time (whatever `yukti` targets via `YUKTI_CONFIG`).
