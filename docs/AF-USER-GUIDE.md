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

On Android an APK you already have - a CI artifact, a download - is installed by
naming it: `yukti install android-qa --apk path/to/app.apk`, no build step. A
variant that always installs the same artifact can carry the path as
`variants.<v>.apkPath` instead. See RUNBOOK, "An APK that is already built".

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

### Check a flow without a device

```bash
yukti flow --check .yukti/flows/46-share-report.json
```

This builds the flow and stops: it reads every step, resolves the blocks an
`include` pulls in and the variables a step uses, and refuses a verb it does not
have, a key the verb does not read, or a condition it does not know. What it
reads is how a step is written, not whether the platform you will run it on has
what the step asks for: `pressKey Back` is written correctly and exists only on
Android, and only a run says so.

Nothing is tapped and no simulator or emulator is needed, so it also answers for
the steps that a `when` keeps off most runs - the ones a real run is least likely
to reach. It writes no result file: nothing ran.

### The flow format (if you hand-edit)
A flow is `{ "name": "...", "steps": [ ... ] }`. Common step verbs:

| Verb | Meaning |
|---|---|
| `{"do":"tapText","value":"Sign In"}` | tap an element by its visible label (preferred — resilient) |
| `{"do":"optionalTapText","value":"Skip"}` | tap if present, don't fail if absent |
| `{"do":"type","value":"165"}` | type into the focused field (`${TEST_EMAIL}` / `${TEST_PASSWORD}` inject creds) |
| `{"do":"scrollToText","value":"Weight History"}` | scroll until visible, and fail the flow if it never becomes visible. `"direction"` is `up`, `down` (the default), `left` or `right`; `"edges":"clear"` asks for it to land away from the edges |
| `{"do":"tapId","value":"submit"}` | tap the element with this a11y id / `resource-id` segment, exact match |
| `{"do":"assertText","value":"Logged"}` | verify the text is on screen (the test's checkpoint — perceivable text only, no scroll). Matches the whole label, case as written; add `"match":"contains"` for a partial match |
| `{"do":"assertId","value":"weight_card"}` | verify an element with this id is on screen |
| `{"do":"assertNotText","value":"Wrong password"}` | verify the text is NOT on the screen as it is now (no scroll). Same matching as `assertText`, `"match":"contains"` included |
| `{"do":"assertNotId","value":"paywall"}` | verify no element with this id is on the screen as it is now |
| `{"do":"screenshot","value":"x.png"}` | capture for review |
| `{"do":"waitFor","value":"Weight History","timeout":15}` | poll until the text is on screen, fail on timeout (seconds, default 10; no scrolling). Matches like `assertText`, `"match":"contains"` included |
| `{"do":"waitForId","value":"weight_card"}` | the same wait, matching the id exactly |
| `{"do":"scroll","value":"down"}` | one swipe: `up`, `down`, `left` or `right` |
| `{"do":"wait","value":3}` / `{"do":"dismiss"}` | sleep a fixed time (prefer `waitFor`) / dismiss a modal |
| `{"do":"tap","x":201,"y":812}` | tap raw coordinates (last resort — brittle) |
| `{"do":"clearText","x":201,"y":400}` | empty the field at those coordinates, and fail if it is not empty afterwards (Android 12+) |
| `{"do":"pressKey","value":"enter"}` | press one key: `back`, `enter`, `home`, `delete`, `tab`, `escape` (`back` is Android only) |
| `{"do":"hideKeyboard"}` | close the keyboard and fail if it is still up — a form longer than one field needs this between fields on Android |
| `{"do":"stopApp","value":"qa"}` | force-stop the app of that variant |
| `{"do":"clearState","value":"qa"}` | wipe the app's data, Android only (the app stops — `launch` it again) |
| `{"do":"include","value":"blocks/sign-in.json"}` | run the steps of another flow file here, as if they were written in this one; `"with":{"TEST_EMAIL":"beth@example.com"}` passes values into it |

Any step, and an `include`, may also carry `"when"` - the conditions under which
it runs at all. See "A step that only runs sometimes" below.

`clearText`, `pressKey` and `hideKeyboard` were measured on Android; their iOS
halves are written and have not been run on a simulator, so treat an iOS failure
in them as a bug in the tool before doubting the app.

A step that fails now fails the flow, and the message names the step. Two
exceptions stay, and they are narrow: `dismiss` and `optionalTapText` tolerate a
label that is not on screen, but not a device that refuses the tap. An unknown
verb, an unknown `"match"` value, a `"match"` on a step that does not take one,
a non-numeric `wait`, and a `scrollToText` whose label never comes into view stop
the flow as well. A flow file that is not valid JSON, one with no steps in it, and
a `${VARIABLE}` that is not set in the environment stop it before the first step
instead of running half of it. So does an `include`: a block that cannot be read,
that is not valid JSON or that has no steps in it, a block that includes itself
or closes a circle, and one nested deeper than a block inside a block. A key the
tool does not know - `wehn` for `when`, `direction` on a step that has no such
key - stops the flow before its first step too: a key nobody reads is a line of
the file that does not do what it says.

### A block several flows share

Signing in, dismissing onboarding, walking to a section — the opening every flow
repeats lives in one file, and each flow runs it by name:

```json
{ "do": "include", "value": "blocks/sign-in.json",
  "with": { "TEST_EMAIL": "beth@example.com" } }
```

The path is read relative to the file that includes it, so a suite moves and is
copied as one directory. The block is an ordinary flow file — `{ "name": …,
"steps": [ … ] }` — and runs on its own, which is how it is debugged.

`"with"` sets variables for that block and only for it: inside it `${TEST_EMAIL}`
is the value passed in, and nothing outside the block changes. A name the include
does not pass falls through to the environment; a name neither of them has stops
the flow before its first step, naming it.

The block's steps enter the run as ordinary steps — numbered in sequence with the
rest, one testcase each in the JUnit file. The run numbers them end to end, so a
failure adds where the step is written: `cannot read the screen - see the error
above (block 'blocks/sign-in.json', step 4)`, and for a step of the flow itself
that sits after a block, `(step 2 of this flow file)`. A flow may include a block
and that block one more; deeper than that, a file that includes itself, and a
circle of files each stop the run with the chain printed.

A `${VARIABLE}` in the path is expanded like one in any other value, so a suite
can keep its blocks behind `${BLOCKS}/sign-in.json`.

The recorder writes flat flows and never an include. Record first, then move the
shared opening into a block by hand.

### A step that only runs sometimes

A consent dialog that appears once per install, a session that is already logged
in, a permission sheet only one platform shows: legitimate states that are not
certain. `"when"` says under which of them a step runs.

```json
{ "do": "tapText", "value": "Accept", "when": { "visible": "We use cookies" } }
{ "do": "tapText", "value": "Allow",  "when": { "platform": "android" } }
{ "do": "include", "value": "blocks/consent.json",
  "when": { "notVisible": "Today" } }
```

The conditions are `visible`, `notVisible`, `visibleId`, `notVisibleId` and
`platform`. Several in one `"when"` all have to hold. On an `include` the
condition is answered once and covers the whole block - never half of it, which
is what asking again at every step of the block would give you the moment the
first step changes the screen.

Three outcomes, and only one of them is a skip:

- it holds - the step runs, and the run says nothing about the condition;
- it does not hold - the step is skipped: a line in the console (`~ step 3
  'tapText' skipped: visible 'We use cookies'`) and a `skipped` testcase in the
  JUnit file, with the condition in the message. The step keeps its number, so
  the numbering of the flow does not shift;
- it cannot be answered - the flow stops. An unreadable screen has no element on
  it, and taken as an answer that would switch steps off silently and keep the
  run green. So: a screen that cannot be read, or that cannot be judged, fails
  the step instead of skipping it.

`visible` and `notVisible` read what a person can perceive - visible text or the
accessibility label, the whole label, case as written, exactly like `assertText`.
`visibleId` and `notVisibleId` match the id exactly, like `assertId`. This is
stricter than `tapText`, which folds case, matches part of a label and also looks
at ids: a condition can therefore skip a step that `tapText` would have found.
That is deliberate - a condition decides whether a step runs, and one that can be
satisfied by markup changes the course of a flow - and it is why a skip is never
silent: the line in the console and the `skipped` entry are how a condition that
is too strict shows up.

`platform` is `ios` or `android`, compared against the platform of the run, and
the skip line names that platform - `skipped: platform 'android' (this run: ios)`
- so a run that resolved its platform differently than you expected says so.

The platform of a run is settled before the first step and printed once, as
`platform: android (from variant 'android-qa')`. It comes from `$YUKTI_PLATFORM`
if that is set, else from the platform of the variant the command is about (the
one you named, or `$YUKTI_VARIANT`), else from the top-level `"platform"` in the
config. If none of the three answers, the run stops there rather than picking a
platform for you.

`optionalTapText` and `dismiss` are the two states that were common enough to be
built into the tool. They stay, and they now have an equivalent you can write in
the flow file, with the label spelled out instead of hidden in the engine:

```json
{ "do": "tapText", "value": "Skip", "when": { "visible": "Skip" } }
```

### Reaching something that is not below

`scrollToText` swiped down and nothing else, so an element above the current
position was unreachable: the flow scrolled away from it, eight times, and
reported that it was not there. It now takes the direction to look in.

```json
{ "do": "scrollToText", "value": "Good Morning", "direction": "up" }
{ "do": "scrollToText", "value": "Sleep", "direction": "left" }
```

`up`, `down` (the default), `left`, `right`. The message on a miss names the
direction it tried, so a wrong one reads as a wrong one.

The same four are the `"value"` of a plain `scroll` step. A direction the tool
does not know used to swipe down and say nothing; it now stops the flow.

**A sideways swipe needs something that scrolls sideways.** On Android it goes
across the widest element on screen that says it scrolls and is wider than it is
tall - a carousel, a tab strip - and when the screen has none, across the middle,
with a line in the run saying so. On iOS it goes across the middle of the screen
and says nothing: the tree there does not report which elements scroll. Written,
not measured - no Mac. That line is worth reading: a horizontal swipe over a
row that does not claim the gesture can be taken for a press on it. Measured on
this app: a `scroll left` across the Settings list opened the share sheet of the
row it crossed. Use a direction where something actually scrolls that way.

Whatever the direction, a `scroll` step does not wait for the app to settle, and
never has. An assertion written straight after one can read a screen that is
still moving; put a `wait` or a `waitFor` between them.

### Landing clear of the edges

An element inside the viewport can still sit under a sticky header or a bottom
bar, where the tap that follows hits the overlay instead of the element.

```json
{ "do": "scrollToText", "value": "Sleep score", "edges": "clear" }
```

`"edges":"clear"` asks for it to end up away from the edges - a fifth of the
band in from each end - and keeps swiping until it does.

Which way those swipes go is decided by where the element is, not by the
direction the search came from. A row at the top edge has to travel down the
screen: a search that walked downwards to find it would push it out of view
instead and then report it missing. `"direction"` is for finding the element;
placing it is a different question, and the step answers that one itself.

If the element never lands clear, the step fails and says where it is: a bottom
bar cannot be moved, and a tap into it is the thing the request exists to
prevent. Without the key, inside the viewport is enough, exactly as before.

Two misses to tell apart. An element that was never on the screen fails with
`not on screen after 8 swipes <direction>`. One that appeared and was swiped away
again says that instead - `came into view at 540 1879 and the swipes took it out
of view again` - because "not on screen" is a false reason for something the run
had already seen.

Sideways, the request has a limit worth knowing: the clear band is a little over
half the width and a swipe travels three fifths of the scroller, so on a narrow
screen an element at one edge can fly past the other and be nudged back until the
swipes run out. The step fails with the position it could not place; place it
with a `scroll` of your own instead.

### Saying something is NOT there

`assertNotText` and `assertNotId` are checkpoints for what must be gone: the
error message after a valid retry, the paywall a subscriber must not see, the row
that was deleted, the account tab a logged-out user must not have.

```json
{ "do": "assertNotText", "value": "Wrong password" }
```

They are about the screen as it is now, and they never scroll: swiping cannot
prove that something is absent, and it changes the state the next step is about
to check. "Not anywhere in this list" is a `scroll` step of your own followed by
the assertion.

Save it in `.yukti/flows/` and it's part of the suite the next Run All.

---

## Credentials

Enter the test account **email/password** once in the Build bar → **Set**. They
stay in the panel's memory (localhost only, never written to disk) and inject
into flows via `${TEST_EMAIL}` / `${TEST_PASSWORD}`. A flow that reaches one of
them without it being set stops and names it - it used to type the text
`${TEST_PASSWORD}` into the field and carry on green.

## First-time setup on a machine

Open the QA panel → **Doctor** runs `yukti doctor` and shows any missing host
tools (Xcode + a Simulator runtime, `idb`, `node@22`, `cocoapods`; `adb`/emulator
for Android) with fix steps. Fix those once and you're set.
