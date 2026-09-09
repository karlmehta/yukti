# AF × YUKTI — the built-in mobile QA experience

The category claim AF gets to own:

> **AgentFoundry is the only IDE where you write a mobile app, its tests, and the
> agent that fixes both — in one loop. The app tests itself as you build it.**

Every other IDE treats tests as text you write and run *somewhere else* (a CI
runner, a device farm, a separate app). AF collapses three things into one
surface: the **running app**, its **tests**, and the **coding agent**. That
triangle is the moat. YUKTI is the engine; this doc is the experience AF builds
on top of it.

This is a UX spec for AF's coding-agent, grounded in APIs YUKTI already exposes
(each surface below cites the endpoint it rides on — nothing here is vaporware).

---

## Design principles

1. **Tests are first-class, not a plugin.** A "QA" icon in the activity bar,
   peer to Source Control — not a webview buried in a menu.
2. **Zero terminal, zero config.** Detect the project, run doctor, scaffold,
   one click to green. A developer never types an `export` or a CLI command.
3. **Record, don't script.** You author a test by *doing it* on the live device
   inside the IDE. AF captures the steps. (Playwright codegen — but for mobile,
   in-editor.)
4. **The agent closes every loop.** Authoring, healing, triage, and the fix are
   all one keystroke because the agent is already in the room.
5. **The device lives in the IDE.** The simulator/emulator streams inside AF,
   beside the flow — not in a separate window you alt-tab to.

---

## The surfaces

### A. Test Explorer (activity bar)
A tree: **Suites → Flows → Steps**, each with a ✓/✗ badge, last-run time, and
duration. Click a flow to open it; click a step to jump the device to that
point. Filter by status ("show only failing"). *Rides `GET /api/flows`,
`/api/flow`.*

### B. Device Mirror (center panel)
The live simulator streamed into AF, with a build bar on top: **variant**
picker, **branch/tag** field ("test `release/1.24.30`"), test creds, and
**⚙ Build & Launch**. Boot state, app version, and device shown inline. *Rides
`GET /api/screen` + `/api/ui`, `POST /api/up`, `GET /api/variants`.*

### C. Recorder (author by doing)
Hit **● Record**; every tap/type on the mirror becomes a step in a live list.
Stop, name it, **Save** → a flow file appears in the tree. AF snaps selectors to
stable accessibility labels (not raw coordinates) so flows survive layout
changes. *Rides `POST /api/tap|type|dismiss` + record-and-replay.*

### D. Run (inline everywhere)
- **CodeLens** above each flow file: `▶ Run | ● Record | ✨ Heal`.
- **Gutter decorations** on the flow's steps: green/red after a run.
- **Run All** with a **continuous soak** toggle (loops) for overnight stability
  runs. Per-flow ✓/✗ + a pass/fail summary stream into a results panel.
  *Rides `POST /api/run`, `/api/run-suite` (`loops:0` = soak).*

### E. Failure Inspector
Click a ✗ and AF opens a three-pane view: **the failing step**, the
**screenshot at failure** next to the **last-known-good screenshot**, and the
**accessibility tree** at that moment. One button: **"Ask agent to fix."**

### F. Agent-native actions — *the part only AF can ship*
Because AF's coding agent already understands the codebase AND can drive the
device, it can do things a standalone test tool never could:

- **Generate tests from a screen or a PR.** "Write tests for the weight-logging
  screen" → the agent reads the RN route/component, drives the live screen to
  discover states, and proposes a flow. Reviewable as a diff.
- **Self-heal on drift.** When a selector breaks (button relabeled, moved), the
  agent repairs it against the live a11y tree and opens a one-line diff instead
  of a red build. *Rides the `POST /api/heal` seam — `YUKTI_AI_CMD` points at
  AF's own agent.*
- **Triage a run.** After a soak, the agent clusters failures into *real
  regression* vs *flaky* vs *selector drift*, links each to the commit that
  likely caused it, and drafts the issue.
- **Natural-language authoring.** "Test that logging weight updates the Today
  card total" → the agent writes the flow, runs it, and shows you green.

### G. Version × Device Matrix
Run the suite across **versions** (git tags) × **devices** in a grid. Cell =
pass/fail; click for the run. A **regression diff** between, say, `1.24.9` and
`1.24.30` highlights exactly which flows newly broke. *Rides `/api/up` with a
git ref per column + `/api/run-suite` per cell.*

### H. CI, in one click
"Export to CI" generates a GitHub Actions workflow (macOS runner) from the
current suite: PR status checks + a nightly soak. The same flows that run
locally run in CI — no translation. *YUKTI already ships this workflow template.*

---

## Onboarding (the first 60 seconds)

1. Developer opens a mobile repo. AF detects RN/Expo/Flutter/native and shows a
   banner: **"Enable built-in QA automation?"**
2. Click → AF runs **`yukti doctor`**, rendering missing host tools (Xcode sim,
   idb, node@22, cocoapods) as a checklist with **Fix** buttons.
3. AF scaffolds `.yukti/` — a config auto-filled from the project's build
   schemes, and an empty flows dir.
4. AF offers: **"Generate a starter suite from your app's routes?"** → the agent
   produces login + core-screen smoke tests.
5. **Build & Launch** → green. Done, no terminal touched.

---

## What ships when (phasing)

- **P0 — the panel is real.** Embed Studio as the QA activity-bar view: test
  explorer, device mirror, build/version bar, run + soak, recorder. This is
  mostly wiring the existing webview + APIs; it already stands out.
- **P1 — agent-native.** NL authoring, self-heal diffs, Failure Inspector →
  fix, CodeLens/gutter. *This is the differentiator — prioritize it.*
- **P2 — scale.** Version×device matrix, CI export, failure triage/clustering,
  Android parity, optional cloud device-farm backend.

---

## Why this wins

- **Cursor / VS Code / JetBrains / Xcode:** tests are files you write by hand and
  run elsewhere; the device is a separate app; no agent in the loop.
- **Standalone mobile test tools (Maestro, Appium, Detox):** powerful, but they
  live outside your editor and have no coding agent — authoring and fixing are
  manual.
- **AF:** the running app, the tests, and the agent that writes+heals both are
  one surface. Open a mobile repo, and it can test itself — and fix itself —
  before you've finished the feature. **No other IDE can say that.**

YUKTI is MIT and vendor-neutral, so this ships as a built-in without a licensing
or lock-in story. Each team's actual test suite stays in *their* repo
(`YUKTI_FLOWS_DIR`); AF supplies the experience, not the tests.
