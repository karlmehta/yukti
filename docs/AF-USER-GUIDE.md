# Using the YUKTI QA panel in AF (developer guide)

How to load a test suite, point it at any app version (iOS or Android), run the
whole suite, and add new tests — all from inside AgentFoundry, no terminal.

---

## 1. Load your tests (the 45 cases)

A project's tests are just JSON flow files in a folder. YUKTI reads them from
`YUKTI_FLOWS_DIR`; AF sets this to your project automatically.

- **In AF:** open the mobile repo → open the **QA** panel (activity bar). The
  **Test Cases** list populates from `<project>/.yukti/flows/`. That's it — all
  45 XSpan cases appear, grouped, with step counts.
- **If starting fresh:** drop your `.json` flow files into `<project>/.yukti/flows/`
  and a `xspan.config.json` (build variants) into `<project>/.yukti/`. AF picks
  them up on open. The 45 XSpan flows live in the xspan-mobile repo under
  `.yukti/flows/` (private — they ship with the project, not with YUKTI).

Under the hood AF launches: `YUKTI_CONFIG=<project>/.yukti/xspan.config.json`
`YUKTI_FLOWS_DIR=<project>/.yukti/flows` — you never type this.

---

## 2. Point it at an app version (Apple or Google)

You test whatever build is installed on the simulator/emulator. Three ways to
put a specific version there, all from the **Build bar** at the top of the panel:

### a) Build a version from source (any branch/tag)
1. Pick a **variant** (e.g. `dev`, `prod`, `android-dev`) from the dropdown.
2. Type a **branch or tag** in the version field — e.g. `release/1.24.30`.
3. Click **⚙ Build & Launch**.

AF checks out that ref, builds a simulator/emulator app, boots the device,
installs, and launches — streamed live. Now **Run All** runs the same 45 tests
against `1.24.30`. Repeat with `1.24.9` to compare.

- **iOS:** uses the iOS variant's scheme/configuration (Xcode Simulator).
- **Android:** pick the `android-dev` variant → Gradle build → Android emulator.
  Same 45 flows, same run — YUKTI's engine is cross-platform (label-based taps
  work on both; a few coordinate taps may need one Android validation pass).

### b) Run against a store / QA build already on the device
If QA already installed a `.app`/`.apk` (e.g. the 1.24.30 QA build) on a booted
simulator/emulator, just skip the build: boot the device, make sure the app is
installed, and click **Run All**. YUKTI drives whatever is on screen.

### c) Pull an official build (EAS/CI artifact)
If your CI produces a **simulator** build, `yukti pull <variant>` fetches it and
`Build & Launch` installs it — no local compile. (Device `.ipa`/`.apk` won't run
on a simulator; you need a simulator-profile artifact.)

> **Version × device matrix:** to run the 45 across several versions/devices at
> once, boot multiple simulators and open one QA panel per device
> (`YUKTI_STUDIO_PORT` + the same `YUKTI_FLOWS_DIR`). One device runs one flow at
> a time; parallelism = more devices.

---

## 3. Run the 45 tests

- **Run All** → runs every flow in order; per-flow ✓/✗ streams live with
  screenshots, then a pass/fail summary listing any failures.
- **loops = 0** → continuous **soak** (runs the suite on repeat until you stop) —
  use overnight to catch flakiness/regressions.
- **Run one** → click a single test's ▶ (or the CodeLens above its file).
- Failures open the **Failure Inspector**: the failing step + the screenshot at
  failure vs. last-known-good, and a one-click **Ask agent to fix**.

---

## 4. Add a new test (two ways)

### a) Record it (fastest — no code)
1. Click **● Record**.
2. Do the test on the live device in the panel — tap, type, scroll.
3. **Stop**, name it (e.g. `46-share-report`), **Save**. It appears in the tree
   and in `.yukti/flows/`. AF snaps to stable accessibility labels so it survives
   layout changes.

### b) Describe it (agent writes it)
Type what you want in the QA panel's agent box — e.g. *"Test that logging weight
updates the Today card total."* The agent writes the flow, runs it, and shows
you green. Edit/save like any other.

### The flow format (if you hand-edit)
A flow is `{ "name": "...", "steps": [ ... ] }`. Common step verbs:

| Verb | Meaning |
|---|---|
| `{"do":"tapText","value":"Sign In"}` | tap an element by its visible label (preferred — resilient) |
| `{"do":"optionalTapText","value":"Skip"}` | tap if present, don't fail if absent |
| `{"do":"type","value":"165"}` | type into the focused field (`${TEST_EMAIL}` / `${TEST_PASSWORD}` inject creds) |
| `{"do":"scrollToText","value":"Weight History"}` | scroll until visible |
| `{"do":"assertText","value":"Logged"}` | verify text is shown (the test's checkpoint) |
| `{"do":"screenshot","value":"x.png"}` | capture for review |
| `{"do":"wait","value":3}` / `{"do":"dismiss"}` | settle / dismiss a modal |
| `{"do":"tap","x":201,"y":812}` | tap raw coordinates (last resort — brittle) |

Save it in `.yukti/flows/` and it's part of the suite the next Run All.

---

## Credentials

Enter the test account **email/password** once in the Build bar → **Set**. They
stay in the panel's memory (localhost only, never written to disk) and inject
into flows via `${TEST_EMAIL}` / `${TEST_PASSWORD}`.

## First-time setup on a machine

Open the QA panel → **Doctor** runs `yukti doctor` and shows any missing host
tools (Xcode + a Simulator runtime, `idb`, `node@22`, `cocoapods`; `adb`/emulator
for Android) with fix steps. Fix those once and you're set.
