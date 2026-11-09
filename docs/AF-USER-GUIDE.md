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

The platform comes from the variant you pick, and the panel states it at startup
and in `/api/health`; the dropdown shows it per variant. Coordinates recorded by
clicking the screenshot follow that answer - Android taps are recorded in the
screenshot's own pixels, iOS taps in device points - so a flow recorded on one
platform records what that platform's driver accepts.

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
| `{"do":"tapText","value":"Sign In"}` | tap an element by its visible label (preferred — resilient). Add `"in":"<id>"` to tap a link that is part of a longer text: the element inside that one whose whole text is the value is tapped, with one read and no scroll, so no `"timeout"`; words that are only part of a longer text fail (the app has to mark the link with `accessibilityRole="link"`) |
| `{"do":"optionalTapText","value":"Skip"}` | tap if present, don't fail if absent |
| `{"do":"type","value":"165"}` | type into the focused field (`${TEST_EMAIL}` / `${TEST_PASSWORD}` inject creds) |
| `{"do":"type","value":"12a!","shows":"12"}` | type into a field that filters its input; the read-back checks what the field `shows`, not the value sent |
| `{"do":"scrollToText","value":"Weight History"}` | scroll until visible, and fail the flow if it never becomes visible. `"direction"` is `up`, `down` (the default), `left` or `right`; `"edges":"clear"` asks for it to land away from the edges; `"timeout"` (seconds, default 5) is how long it waits at the end of the list for the list to grow |
| `{"do":"tapId","value":"submit"}` | tap the element with this a11y id / `resource-id` segment, exact match |
| `{"do":"tapId","value":"slider-track","at":{"x":"50%"}}` | tap a point inside that element instead of its centre: `x` and `y` are whole shares of its width and height from its left and top edge, written with `%`; one left out stays at the centre, and `100%` is the last pixel inside. A share, not pixels, so the same flow sets the same slider stop on a phone and on a tablet. The point has to be on the screen. On iOS a thumb with an id of its own over the point fails the step as covered - tap the thumb by its id, or the track away from it. Check the value the app shows or saves after the tap |
| `{"do":"assertText","value":"Logged"}` | verify the text is on screen (the test's checkpoint — perceivable text only, no scroll). Matches the whole label, case as written; add `"match":"contains"` for a partial match; add `"in":"<id>"` to look only inside that element |
| `{"do":"assertId","value":"weight_card"}` | verify an element with this id is on screen |
| `{"do":"assertBox","value":"Reconnect","box":{"minX":16,"maxX":"95%"}}` | verify the box of the element with this label: `minWidth`, `minHeight`, `maxWidth`, `maxHeight` for the size, `minX`, `minY`, `maxX`, `maxY` for the edges. Pixels (`48`), dp (`"48dp"`) or a share of the screen (`"5%"`) |
| `{"do":"assertBoxId","value":"primary-cta","box":{"minWidth":"48dp","minHeight":"48dp"}}` | the same check, matching the id exactly - here the touch-target minimum |
| `{"do":"assertBoxId","value":"chat-pill","box":{"above":"tab-bar"}}` | the box against another element, named by its id: `above`, `below`, `leftOf`, `rightOf`, or `apart` (the two do not overlap) |
| `{"do":"tapText","value":"Continue","index":1}` | the second of several equal matches, counting from 0 top to bottom, then left to right. Taken by `tapText`, `optionalTapText`, `tapId`, `clearTextId`, `assertText`, `assertId`, `assertBox`, `assertBoxId`, `waitFor` and `waitForId`; past the last match the step stops and says how many matched. `tapText` with an index does not scroll |
| `{"do":"assertCount","value":"Item","op":"atLeast","count":2}` | count the elements with this text on the screen and compare: `"op"` is `atLeast`, `exact` or `atMost`; matches like `assertText`, `"match":"contains"` included. The number found is in the line and in the report |
| `{"do":"assertCountId","value":"result-row","op":"exact","count":5}` | the same count, matching the id exactly; both take `"in":"<id>"` to count inside one element |
| `{"do":"assertNotText","value":"Wrong password"}` | verify the text is NOT on the screen as it is now (no scroll). Same matching as `assertText`, `"match":"contains"` and `"in"` included |
| `{"do":"assertNotId","value":"paywall"}` | verify no element with this id is on the screen as it is now |
| `{"do":"waitForNotText","value":"Saving...","timeout":15}` | poll until the text is gone from the screen, fail if it is still there at the timeout (seconds, default 10). Matches like `assertNotText`, `"match":"contains"` included |
| `{"do":"waitForNotId","value":"save-sheet"}` | the same wait, by id - for a sheet that closes or a spinner that goes, instead of a fixed `wait`. An unreadable screen is never taken for gone |
| `{"do":"screenshot","value":"x.png"}` | capture for review |
| `{"do":"waitFor","value":"Weight History","timeout":15}` | poll until the text is on screen, fail on timeout (seconds, default 10; no scrolling). Matches like `assertText`, `"match":"contains"` and `"in"` included |
| `{"do":"waitForId","value":"weight_card"}` | the same wait, matching the id exactly; on timeout it says whether the id is not in the tree, is there at zero size, or is outside the screen |
| `{"do":"assertId","value":"week-tab","selected":true}` | the element with this id is on screen and selected; `"checked": true/false` for a checkbox or switch; `waitForId` takes the same keys and waits for the state |
| `{"do":"turnWheel","wheel":2,"value":-1}` | turn the second wheel of a wheel picker (iOS date picker, `NumberPicker`) one row up; minus is up, plus is down, the wheel is read after every row. Check the date on the field after the picker closes |
| `{"do":"swipeId","value":"row-invoice","direction":"left"}` | swipe across one element to show what it hides - a list row's delete button. `"direction"` is where the finger goes, so `left` shows actions on the right of the row; that is the other way round from `scroll`, whose direction names what comes into view. The stroke is 60% of the element's width (of its height for `up` and `down`), centred on it, so it starts and ends inside; only the part on the screen counts, and `YUKTI_SWIPE_SHARE` (1 to 90) changes the share. A stroke too short to read as a swipe (under 48 px on Android, 20 pt on iOS) fails the step instead of tapping the element. `swipeText` does the same for an element found by its text - often the label inside a row rather than the row, so for a row use `swipeId` on its container. On iOS a control with an id of its own under the start point (a chevron, a "more" button) fails the step as covered. Neither scrolls: put a `scrollToText` in front for a row below the fold. A miss reads like `tapId` / `tapText`. On iOS a long swipe can perform the first action at once, and 60% has not been measured there yet |
| `{"do":"waitForId","value":"chat-button","timeout":20,"optional":true}` | the same wait, but a timeout skips the step instead of failing the flow, with the same words |
| `{"do":"scroll","value":"down"}` | one swipe: `up`, `down`, `left` or `right` |
| `{"do":"wait","value":3}` / `{"do":"dismiss"}` | sleep a fixed time (prefer `waitFor`) / dismiss a modal |
| `{"do":"tap","x":201,"y":812}` | tap raw coordinates (last resort — brittle); recorded pixels are scaled from the screen they were recorded on |
| `{"do":"tap","x":"50%","y":"80%"}` | tap a place on the screen rather than a control - here the middle of the width, four fifths down. A share is taken of the screen the run is on (pixels on Android, points on iOS) and does not depend on the recording basis or `YUKTI_TAP_SCALE`, as pixels do; `x` and `y` may mix the two forms. Not yet run on an emulator or a simulator |
| `{"do":"swipe","x":"50%","y":"25%","toX":"50%","toY":"70%"}` | one swipe from a point to a point, each pixels or a share of the screen - a gesture with no element under it and none of the four directions, such as pulling a list down from its top. The finger moves at the speed of `scroll`, with a set duration on both platforms (a drag on iOS; on Android it lets go at that speed); a keyboard that is up is closed first; a start at the very edge triggers a system gesture instead. Not yet run on an emulator or a simulator |
| `{"do":"clearText","x":201,"y":400}` | empty the field at those coordinates (pixels or a share of the screen, as for `tap`), and fail if it is not empty afterwards (Android 12+) |
| `{"do":"clearTextId","value":"email-input"}` | empty the field with this id, and fail if it is not empty afterwards (Android 12+) |
| `{"do":"pressKey","value":"enter"}` | press one key: `back`, `enter`, `home`, `delete`, `tab`, `escape` (`back` is Android only) |
| `{"do":"hideKeyboard"}` | close the keyboard and fail if it is still up — a form longer than one field needs this between fields on Android. Android: Back, pressed only while the keyboard is up, then escape as the fallback, which fails the step if it closed a dialog around the field too. iOS: a drag above the keys, then the "Done" button above the keyboard; Return is never pressed (use `pressKey enter` where the form may take it); the failure lists what was tried |
| `{"do":"stopApp","value":"qa"}` | force-stop the app of that variant |
| `{"do":"clearState","value":"qa"}` | wipe the app's data, Android only (the app stops — `launch` it again) |
| `{"do":"background","value":5}` | send the app of `$YUKTI_VARIANT` to the home screen and keep it there for that many whole seconds (none: 0, at most 600); it stays in the background after the step. Fails when the app was not in front, or still is after Home |
| `{"do":"foreground"}` | bring the app of `$YUKTI_VARIANT` back from the background. Fails when it is not running any more, is already in front, does not come to the front, or comes back as a new process - a cold start is not a return |
| `{"do":"relaunch"}` | stop the app of `$YUKTI_VARIANT` and start it again, its data kept (`clearState` is the one that wipes); fails when it does not come to the front, or comes back as the same process |
| `{"do":"setPermission","value":"notifications","state":"denied"}` | set one permission of the app of `$YUKTI_VARIANT` before it starts: `granted`, `denied` (not asked again) or `unset` (the dialog comes up). One name for both platforms (`notifications`, `camera`, `microphone`, `location`, `photos`, `contacts`, `calendar`, `motion`, `reminders`, `health`) or an Android name with a dot; on iOS camera, notifications and health need `applesimutils`. Android reads the state back and fails when it did not take; before Android 13 only `granted`. A permission the platform lacks skips the rest of the flow (`platform:`) |
| `{"do":"openUrl","value":"home"}` | open a screen by its key — the address is the variant's `urlBase` plus the key, so no flow carries an environment; delivery only, and the app navigates after the step, so follow it with `waitFor` / `waitForId`, not an assert |
| `{"do":"include","value":"blocks/sign-in.json"}` | run the steps of another flow file here, as if they were written in this one; `"with":{"TEST_EMAIL":"beth@example.com"}` passes values into it |

Any step, and an `include`, may also carry `"when"` - the conditions under which
it runs at all. See "A step that only runs sometimes" below.

A step may carry a `"title"` - what it is for, in your words:
`{"do":"tapId","value":"nav-account","title":"open the account screen"}`. The
JUnit file then names the step `03 open the account screen: nav-account`
instead of `03 tapId nav-account` (a step from a block keeps the block in
front), and the console prints `step 3 'tapId' "open the account screen"`
before the step runs. The value stays after the title, shown the way it is
without one, so a block that two flows include with different `"with"` values
names its steps differently in each. The step runs exactly as it would without
a title, and a `${VARIABLE}` in a title is printed as written, never expanded.

`"index"` picks one of several equal matches - three fields with no captions,
a grid of the same cards, rows that repeat the same options under the same ids.
It counts from 0 in the order of the screen, the same on both platforms: rows
top to bottom, then left to right by the centre (two elements are one row when
their vertical centres differ by less than half the height of the smaller one).
Only what is on the screen, of real size, counts, and with `"in"` only what is
inside that element. Only the matches that match as closely as the best one
count: for `tapText` a caption next to a button matches less closely than the
button and is left out, and a row labelled on itself and on its text counts
once. An index past the last match fails the step with the number that matched,
and the number left out, instead of acting on the first one. `assertCount` and
`assertCountId` count the same matches and compare: `atLeast` is the guard that
a list filled, `exact` and `atMost` close it from the other side. On iOS a
container marked accessible arrives as one element (#88), so a count there is
what the accessibility tree reports.

`assertBox` and `assertBoxId` measure the box the lookup already reads. A
constraint is a plain number of pixels (`48`), a number of dp (`"48dp"`), or a
whole share of the screen (`"5%"`) - of its width for `minWidth`, `maxWidth`,
`minX` and `maxX`, and of its height for the other four.

Write the rules in dp. A touch target is 48dp on Android and 44pt on iOS, and
on a 320 dpi screen that is 96 pixels: a flow that writes `48` there asserts
half the minimum and passes on a control nobody can hit. Android converts with
the density the device reports, an override density included; on iOS the frame
is already in points, so a dp is a point and the conversion is the identity.
The failure says both numbers - `expected width at least 48dp = 96 px (is 48)` -
because the first names the line to change and the second says what it came to
on this screen.

A step with no constraint is refused before the run: an assertion that only
says the element is on the screen is `assertId`, and saying it twice is not a
stronger test.

`above`, `below`, `leftOf`, `rightOf` and `apart` measure the box against
another element, found by id, on the same read of the screen. Use them where the
expected result names two elements - "the pill is above the tab bar", "the cards
do not overlap": the place of the other element changes with the device and the
content, and a share of the screen only guesses it. Edges that touch keep the
relation; `below` says nothing about the horizontal place. The failure prints
both boxes.

`type`, `clearText`, `clearTextId`, `pressKey` and `hideKeyboard` were measured
on Android; their iOS halves are written and have not been run on a simulator, so
treat an iOS failure in them as a bug in the tool before doubting the app.
`swipe` and a share of the screen in `x`/`y` have not been run on either
platform yet, only against the engine's fake devices.

A step that fails now fails the flow, and the message names the step. Three
exceptions stay, and they are narrow: `dismiss` and `optionalTapText` tolerate a
label that is not on screen, but not a device that refuses the tap, and a
`waitForId` with `"optional": true` tolerates a timeout, but not a screen that
cannot be read. An unknown
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
rest, one testcase each in the JUnit file, named with the block it came from:
`03 [blocks/sign-in.json] type 22 chars`. The run numbers them end to end, so a
failure adds where the step is written: `cannot read the screen - see the error
above (block 'blocks/sign-in.json', step 4)`, and for a step of the flow itself
that sits after a block, `(step 2 of this flow file)`. Blocks may include blocks
down to eight levels; a ninth, a file that includes itself, and a circle of
files each stop the run with the chain printed.

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

The conditions are `visible`, `notVisible`, `visibleId`, `notVisibleId`,
`zeroSizeId` and `platform`. Several in one `"when"` all have to hold. On an `include` the
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

`zeroSizeId` holds when an element with this id is in the tree at zero size -
the case of a control that grows in with an animation and sometimes stays at its
starting point - and no element with the same id can be tapped instead. It does
not matter whether the point lies on the screen. `notVisibleId` holds in that
case too, and also when the id is not there at all; `zeroSizeId` is the one that
tells the two apart.

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

A wait that may end without its element is `"optional": true` on `waitForId`.
On timeout the step is skipped - a `~` line and a `skipped` testcase whose
message starts with `optional wait ended, the flow went on:` and names the case -
and the flow goes on. With `zeroSizeId` it makes a recovery path that costs
nothing when the element behaves:

```json
{ "do": "waitForId", "value": "chat-button", "timeout": 20, "optional": true },
{ "do": "include", "value": "blocks/remount.json", "when": { "zeroSizeId": "chat-button" } },
{ "do": "waitForId", "value": "chat-button", "timeout": 40 },
{ "do": "tapId", "value": "chat-button" }
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

The search stops where the list ends, not after a count. Two minutes of
swiping is a safety net; a list that stops moving earlier ends the search
earlier. The step
swipes inside the list itself, starting on a line of text where it can, away
from anything inside it that says it scrolls, a slider and a chart, and clear
of the strips at the sides of the screen where a screen takes the touch as the
back gesture. It only
calls it the end when a second, shorter
swipe from another point moves nothing either. The status bar clock does not
count as movement: only the list is compared.

A raised keyboard is closed before the first swipe, and the run says so. A swipe
that starts on the keys is taken as glide typing and puts a word into the field,
so the step asks first; if the keyboard does not close, the step fails and names
the keyboard. The field loses its focus with the keyboard: a flow that types
after the search taps the field again first. A label already in view needs no
swipe, and then the keyboard is left as it is.

The misses to tell apart:

- `reached the end of the list going down and it did not grow for 5s, 'Sleep
  score' is not in it` - the list was searched to its end in that direction,
  from where the search started, and then the step waited that long for a lower
  part laid out late. A screen that needs longer gets `"timeout"` on the step.
  A search that starts halfway down a list and goes down has not looked above.
- `still moving after 120s of swiping down, 'Sleep score' not found` - the list
  is longer than the safety net. The line `· search N swipes M ms` before it
  says how far the search got. Two minutes is long on purpose: it is what the
  slowest reader needs for the thirty swipes the search used to allow. A feed
  that never ends, or a list whose rows carry no text to compare, reaches it
  every time - that is a slow red step, not a hung run.
- `no scrollable list on screen - searched 8 swipes down, 'Sleep score' not
  found` - the screen has no element that says it scrolls that way, so the step
  swiped down the middle eight times, as it used to, and cannot say where the
  list ends. The run prints a warning when this starts.
- `came into view at 540 1879 and the swipes took it out of view again` - the run
  had seen it, and "not on screen" would be a false reason.
- with `"edges":"clear"`, `is at the end of the list and cannot be moved clear of
  the band edge` - the element is there, the list cannot move it any further, and
  it is still under the edge. Usually that is content hidden under a fixed bar.

`tapText` searches the same way, waits at the end of the list the same way
(`"timeout"` on the step sets it), and carries the same reasons after
`no element matching '<label>'`.

Sideways, the request has a limit worth knowing: the clear band is a little over
half the width and a swipe that places an element travels two fifths of the
visible list, so on a narrow screen an element at one edge can fly past the other
and be nudged back until the time runs out. The step fails with the position it could not place; place it
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

When something has to go away first - a save sheet that closes, a spinner -
wait for it instead of pausing with `wait`:

```json
{ "do": "tapText", "value": "Save" },
{ "do": "waitForNotId", "value": "save-sheet", "timeout": 15 }
```

`waitForNotText` and `waitForNotId` pass as soon as the element is gone and fail
if it is still there at the timeout. A screen that cannot be read - an app that
crashed - is never taken for gone: the step fails and says so.

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
