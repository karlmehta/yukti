# YUKTI — QA team runbook

How to run mobile QA on the local iOS Simulator with YUKTI, on every build
(dev / qa / prod). No BrowserStack, no physical devices.

## One-time setup (per Mac, ~30 min mostly download)

```bash
# 1. Full Xcode (not just Command Line Tools)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadPlatform iOS            # iOS simulator runtime (~8 GB)

# 2. Toolchain
brew install node@22 cocoapods watchman
brew trust facebook/fb && brew install idb-companion
/usr/bin/python3 -m pip install --user fb-idb

# 3. YUKTI
git clone https://github.com/karlmehta/yukti ~/yukti && chmod +x ~/yukti/yukti
~/yukti/yukti doctor                        # verifies everything above
```

## Run against a build

```bash
cd ~/workspace/your-rn-app                 # the app repo
export YUKTI_CONFIG=~/yukti/examples/example.config.json
export TEST_EMAIL='...'  TEST_PASSWORD='...'   # a QA test account (never your own)

~/yukti/yukti up dev                        # build (signed) + boot sim + install + launch
for f in ~/yukti/flows/*.json; do ~/yukti/yukti flow "$f"; done
```

Screenshots land in `$TMPDIR` (the flows name them). Review, or feed them to an
AI agent for exploratory follow-up.

### An APK that is already built (Android)

`up` builds first, so `install` takes the APK the build step just produced. When
the artifact came from somewhere else - an earlier CI job, a download, a colleague -
name it and skip the build:

```bash
~/yukti/yukti boot
~/yukti/yukti install android-qa --apk ~/Downloads/app-qa-release.apk
~/yukti/yukti launch android-qa
```

A variant that always installs the same artifact can say so in the config
instead, as `variants.<v>.apkPath`. Three sources, in this order: `--apk`, then
`apkPath`, then the APK `yukti build` produced. A path that is not a file stops
the run and says which of the three named it, rather than handing an empty path
to `adb`.

`apkPath` is a path, not a shell word: `~` in it is a directory called `~`, so
write the path out or keep it relative to the config. A relative `apkPath` is
relative to the config file that names it, not to the
directory the command was typed in - the same config installs the same file from
a laptop and from a CI job. A relative `--apk` is what you typed, so it is
relative to where you typed it.

`--apk` belongs to `install` alone. `up` builds and then installs what it built;
naming an artifact means skipping the build, which is `boot`, `install --apk`
and `launch` - and `up --apk` stops at once as an unknown variant rather than
starting a build nobody wanted.

`--apk` is Android only: on iOS `install` takes the `.app` that `yukti build` or
`yukti pull` left, and the flag stops the run rather than being ignored.

## Which variant

| Variant | Backend | Firebase project | Test account |
| --- | --- | --- | --- |
| `dev` / `qa` | api-qa.example.com | your-qa-firebase-project | a **QA-tenant** account (e.g. qa-test@example.com) |
| `prod` | api.example.com | your-prod-firebase-project | a dedicated **prod test** account (not a real member) |

A QA account only exists in its own Firebase project — a prod account will 400 on
a QA build and vice-versa. Use the matching account per variant.

## Which platform

One run drives one platform, resolved before the command starts and printed as
`platform: android (from variant 'android-qa')`. Three sources, in this order:

1. `$YUKTI_PLATFORM`, which beats everything - this is how CI pins a run.
2. The platform of the variant this command is about: the one you named
   (`yukti up android-qa`), else `$YUKTI_VARIANT`.
3. The top-level `"platform"` in the config.

A variant that names its own platform states a fact about that variant, so
`$YUKTI_PLATFORM` saying one thing and the variant in hand another is not a
preference to resolve: the run stops and prints both. Pin the environment for a
suite, name the variant for a one-off, and the two never need to argue.

When none of the three answers, the run stops and says so. It does not pick one:
a run that guesses the platform drives the wrong tooling and reports ordinary
failures several steps away from the cause. `yukti init` writes the top-level
field, so a config it made always answers; a hand-written config that keeps the
platform only inside its variants needs either a variant on the command line,
`$YUKTI_VARIANT`, or that field added.

The QA panel answers the same question the same way, and hands its answer to
every CLI call it makes rather than letting the child reach one of its own. It
prints the answer and where it came from at startup
(`platform: android (from variant 'android-qa')`) and serves both at
`/api/health`, and the variant dropdown shows the platform each variant will
actually run - a variant that names none shows the top-level one. The
contradiction above stops the panel as it stops the CLI: it reports the same
sentence at startup, at `/api/health` and in the panel's log, and claims no
platform while it stands.

That answer also decides what a tap recorded in the panel is written against. On
Android the screenshot is in physical pixels and `adb shell input tap` takes the
same pixels, so the basis is the screenshot itself; on iOS the PNG is a 2x/3x
raster and carries no point size, so the device's point size stands (an iPhone 16
Pro is 402x874, and `YUKTI_DEVICE_PT_W` / `YUKTI_DEVICE_PT_H` set it for another
device - set by hand, they win on both platforms). Recording Android taps
against a fixed iPhone pair is the reason this is written down: the coordinates
land somewhere else on the screen, the tap misses, nothing fails, and the run
breaks several steps later on an assert about something unrelated.

## Add a test case

Flows are JSON in `flows/`. Steps: `wait`, `waitFor`, `waitForId`, `screenshot`,
`tap {x,y}`, `tapText`, `optionalTapText`, `tapId`, `type`, `clearText {x,y}`,
`pressKey`, `hideKeyboard`, `scroll`, `scrollToText`, `dismiss`, `assertText`,
`assertId`, `launch`, `stopApp`, `clearState`, `include`. Coordinates are
**points**
(iPhone 16 Pro = 402×874). Prefer `tapText` (finds by accessibility label) over
raw coords so flows survive layout changes. `${VARS}` in `value` expand from env,
and a variable that is not set stops the flow before its first step, naming it -
the value used to be typed in as written, sixteen literal characters of
`${TEST_PASSWORD}`, under a log line that said `type 16 chars`. A `$` followed by
a name is read as a variable wherever it appears in a value, and there is no way
to write a literal one: a caption like `$USD`, or a password with a `$` in the
middle of it, has to come from the environment too.

### Assertions, and matching by id

`assertText` is the checkpoint of a flow, so it matches only what a person can
perceive: the visible text or the accessibility label of an element that is on
screen right now - real size, centre inside the window. It never matches a
resource-id, a class name or any other markup, and it does **not** scroll: put
`scrollToText` in front of it when the target sits below the fold. That step
fails the flow if the label never comes into view, so the assertion after it
runs on the screen it was written for.

The match is the **whole label, case as written**. Leading and trailing spaces
do not count, and a two-line caption reads as one line. A partial match is
available, and has to be asked for:

```json
{"do":"assertText","value":"Network & internet"},
{"do":"assertText","value":"internet","match":"contains"}
```

`"match":"contains"` folds case as well, which is what makes it weak: `net`
then passes on a screen that only says `Network & internet`. Use it where a
label carries a value that changes, and prefer the default everywhere else.

The locator verbs - `tapText`, `optionalTapText`, `scrollToText` - are not
assertions, and their matching is unchanged: they still match a substring and
fold case, and they rank the candidates. What `scrollToText` does on a miss is
new, and it is below. Naming a button is not a statement about its
capitalisation; asserting one is.

The other direction is `assertNotText` and `assertNotId`: the checkpoint for
what must be gone - the error message after a valid retry, the paywall a
subscriber must not see, the row that was deleted. They match exactly as their
positive halves do, `"match":"contains"` included, and they fail when the element
IS found.

They are about the screen as it is now and they never scroll. Eight swipes cannot
prove that something is absent, and they change the state the next step is about
to check; "not anywhere in this list" is a `scroll` of your own followed by the
assertion. The case they are built around is the other one: a screen that could
not be read has no element on it either, and a negative assertion that took that
for an answer would pass on every broken dump. Both of them fail instead - an
unreadable screen, and a screen whose own bounds are missing so that nothing on
it can be called visible, are failures of the step, never absence.

`match` belongs to the assertion, so `assertText` and the wait that follows the
same rules - `waitFor`, below - are the only steps that take it. Any other step
given a `match` fails instead of ignoring it: a step that reads as exact while
the verb folds case is a suite that is weaker than it looks.

"On screen" means inside the window and of non-zero size. It does not model
overlap: a label underneath a modal or an alert is still reported as on screen,
on both platforms, because the dialog and the label live in the same tree.

```json
{"do":"scrollToText","value":"Weight History"},
{"do":"assertText","value":"Weight History"}
```

`tapId` and `assertId` take an accessibility identifier (iOS) or the last segment
of an Android `resource-id` - `com.app:id/email` matches `email` - and require an
exact match: no text fallback, no ranking. An empty value always fails, so a
misspelled key stops the run instead of tapping a random point. Neither verb
scrolls, and when several elements share one id the first usable one in the tree
wins - an element with no size is skipped.

```json
{"do":"tapId","value":"submit"},
{"do":"assertId","value":"weight_card"}
```

Discover labels/coords for a screen:
```bash
~/yukti/yukti ui | python3 -m json.tool | less      # accessibility tree
~/yukti/yukti find "Sign In"                         # -> "201 705"
```

### When a step fails

A step that ends with a non-zero status now fails the flow, and the message
names it: `step 7 'tapText' failed (exit 1)`. Until now only an explicit failure
inside a verb could stop a run - `adb` refusing a tap, a launch of a package
that is not installed, a `clearText` on a dead device all reported PASS, and the
JUnit file said `failures="0"`.

Sixteen more ways a flow stops, the first four of them typos that used to pass:

- a step name the runner does not know;
- a `"match"` value that is neither `exact` nor `contains`;
- a `"match"` key on a step that does not take one;
- a `wait` whose value is not a number - `sleep` refuses it;
- a `"value"` on a `hideKeyboard`, which has nothing to read one with;
- a `pressKey` naming a key the tool does not have;
- a `pressKey` asking for `back` on iOS, which has no Back key;
- a `scroll`, or a `scrollToText`, given a direction that is not `up`, `down`,
  `left` or `right` - the unknown ones used to swipe down and say nothing;
- an `"edges"` value other than `clear`, and a `"direction"` or an `"edges"` on
  a step that does not take one;
- a `scrollToText` with `"edges":"clear"` whose element comes into view and never
  lands clear of the edges - a row under a sticky bar, most often;
- a `clearText` whose coordinates land on something that is not a text field;
- a `clearText` whose coordinates land on a disabled field, or on one that
  cannot take focus, or a tap that leaves focus in a different field than the
  one named;
- a condition that cannot be answered: a screen that could not be read, or one
  whose own bounds are missing so that nothing on it can be called visible;
- a `"when"` that is not an object of conditions, is empty, names a condition the
  tool does not know, carries a value that is not text, or names a platform that
  is neither `ios` nor `android` - all of them before the first step runs;
- a key the tool does not know on a step or on an `include`, `wehn` for `when`
  first among them: a key nobody reads is a line of the file that does not do
  what it says, and a mistyped condition means a step that runs every time;
- a `clearText` that ran and left text in the field, or ran on Android 11 or
  older, where the key combination it uses does not exist. There is no quiet
  fallback to deleting character by character: on such a device the step says so
  and stops. The version check is what stops it, and it fires before the first
  key is sent. What it covers for is the line after it: on Android 11 the shell
  answers an unknown command with its usage text and a zero exit code, so a
  refusal from the key combination itself would go unnoticed there - and the
  read-back at the end is the guard if this threshold is ever wrong again.

### Forms with more than one field (Android)

While the keyboard is up it covers the controls under it, so a flow that fills a
second field, or taps Save, has to close it first: `hideKeyboard` between the
fields. It asks the input method itself whether a keyboard is up, presses escape,
and asks again - if one is still up after that, and after Back, the step fails
rather than letting the next tap land on a key.

Two consequences worth knowing before writing flows:

- the field loses focus when the keyboard closes (measured on API 35), so tap the
  field again before typing into it - `type` goes to whatever holds focus, and
  with none it goes nowhere;
- `pressKey` is the general form and `hideKeyboard` is built on it. Use
  `pressKey enter` to submit a form from the keyboard, and `hideKeyboard` when
  what you need is the keyboard gone. `pressKey back` is not a way to close a
  keyboard: on a screen with nothing to go back to it leaves the app, which is
  what it did to this rig at the second press.

`clearText` empties a field with select-all and one delete, then reads the field
back and fails if anything is left. It never prints what the field held - a
password reaches the log as a count and nothing else. The field it clears is the
one the tap focused: when the keyboard opens and the layout moves, the field is
no longer under the coordinates that reached it, and the step says so in a
warning rather than reading a different node.

`pressKey tab` moves focus without a tap, which reaches a field the keyboard is
covering - the keyboard stays up through it. It is not a way to walk from field
to field, though: it follows the whole focus order. On a two-field form measured
here the second field was three presses away, behind a button and a dropdown,
and that count belongs to that layout and no other. Tap the field, or close the
keyboard and tap it.

Not everything that looks like a field is one. A composer or a search bar can be
a plain view that carries the placeholder as its accessibility label and becomes
a real text field only once it is tapped - `clearText` refuses it until then,
and correctly: there is nothing to clear yet. Tap it first, then clear.

One contract to know before pointing it at a field that is not a plain text box:
it deletes, and a delete on an empty input means whatever the app decides. In a
chip field it removes the last chip, in a split OTP input it moves into the
previous cell. That is true of the delete the verb sends and of the one it sends
to tell an empty field from a hint.

The flow file itself is now read in full before the first step runs, and a file
the runner cannot turn into steps stops the run there: JSON it cannot parse, no
`steps` list, a `null` where a value belongs, a variable that is not set, or a
value carrying the character the runner separates its fields with. A block the
flow includes is read at the same moment and answers the same way, naming itself
rather than the flow that pulled it in. None of those
produced a failure before - the steps were generated straight into the loop,
where the generator's status was lost, so a file that yielded no steps at all
still ended with `flow complete`.

A value is one value, whatever is inside it. A caption that wraps onto two lines
can be written with the line break in it, and the lookup folds whitespace on both
sides of the comparison. The step used to end at that line break: the first half
ran as the step, the second half arrived as a step of its own, and the failure
quoted a string the flow file did not contain.

`dismiss` and `optionalTapText` keep their exception, and it is narrow: a label
that is not on screen is the state those two exist to tolerate. A device that
refuses the tap is not that state, and it fails the flow like any other step.

`dismiss` reads the screen once per round rather than once per label. It knows
nine interstitial labels, and it used to ask the device for the screen for each
of them in turn - nine reads of a screen that nothing had touched, about twenty
seconds on an Android emulator, whether or not anything was there to dismiss.
Now the nine are looked for in one tree, the first one found is tapped, and the
next round reads the screen again, because the tap changed it. A clean screen
costs one read; two interstitials stacked cost three. After the sixth tap the
step stops and says so, without reading the screen a seventh time - it does not
claim to know what is left on it. A screen that answers every tap with another
interstitial is news, not something to keep tapping at.

`scrollToText` takes the direction to look in - `"direction"`: `up`, `down`
(the default), `left`, `right` - and `"edges":"clear"` to land the element away
from the band edges instead of merely inside the band. A plain `scroll` takes the
same four directions as its `"value"`.

On Android a sideways swipe goes across the widest element on screen that says it
scrolls and is wider than it is tall: a carousel, a tab strip. When the screen
has none, it goes across the middle and the run says so - and that line is a warning, not
a note: a horizontal swipe over a row that does not claim the gesture can be
taken for a press on it. Measured on the app under test, a `scroll left` across
the Settings list opened the share sheet of the row it crossed, and a search of
eight swipes did it eight times. A direction belongs where something scrolls
that way.

On iOS the sideways swipe goes across the middle of the screen and says nothing:
the tree there does not report which elements scroll. Written, not measured - no
Mac.

No `scroll` step waits for the app to settle, in any direction, and none ever
has. An assertion written straight after one can read a moving screen: leave a
`wait` or a `waitFor` between them.

`"edges":"clear"` keeps swiping until the element sits a fifth of the band in
from both ends, and fails naming its position if it never does. A row under a
sticky bottom bar cannot be moved, and that failure is the point: the tap that
would follow is the thing the request exists to prevent.

Those swipes follow the element's position, not the search direction. A row at
the top edge travels down the screen; nudging it the way the search walked would
push it out of view and report it missing. `"direction"` finds the element, the
step places it.

A miss reads as one of two things. Never seen: `not on screen after 8 swipes
down`, with the direction, because the direction is what looked. Seen and swiped
away: `came into view at 540 1879 and the swipes took it out of view again` -
"not on screen" would be a false reason for an element the run had on the screen,
which is the class the assertions themselves were fixed for.

One limit, on x. The clear band is a little over half the width, and a sideways
swipe travels three fifths of the scroller it crosses, so on a narrow screen -
or against a list that moves content by the whole swipe - an element at one edge
can fly past the other and be nudged back, until the swipes run out. The step
then fails with the position it could not place, which is the honest answer; if
it happens to you, place the element with a `scroll` of your own and drop the
key.

`scrollToText` fails the flow when the label never arrives: it swipes eight
times, and a last look that finds nothing is the failure, named with the label.
It used to pass on that miss. An empty value fails with its own message.

One verb stays outside the guarantee. `type` on iOS sends the characters one by
one and never reads a status, so it cannot fail. It does not belong in a flow as
its checkpoint - put an `assertText` or an `assertId` after it.

### Waiting for a screen

`wait` is a sleep and nothing else. A flow that synchronises with sleeps has two
bad options: sleep too little and go red at random, or sleep too much and pay
that on every run of every flow.

`waitFor` polls for the element and fails when it does not arrive:

```json
{"do":"waitFor","value":"Weight History","timeout":15},
{"do":"waitForId","value":"weight_card"},
{"do":"waitFor","value":"items in cart","match":"contains"}
```

`timeout` is whole seconds and defaults to 10; a timeout that is not a positive
whole number fails the step rather than falling back to the default. The match
rules are the ones `assertText` uses - the whole label, case as written, with
`"match":"contains"` available - so a wait and the assertion after it agree on
what they are looking at. `waitForId` matches the id exactly, and like every
step but those two it refuses a `match` key instead of ignoring it.

`waitFor` does **not** scroll: it waits for what the screen is about to show,
not for what sits below the fold. Keep `scrollToText` for the fold, and note
that it is not a wait - it swipes between its tries, so on a screen that is
still loading it scrolls the content away instead of waiting for it.

A screen that cannot be read is not the same as an element that has not arrived.
The poll keeps going while the screen is unreadable, and the message on timeout
says which of the two happened.

The step sees only what outlives one poll - the sleep plus the lookup itself,
about a second on a device. Wait for a state that stays, not for something that
flashes: a toast that shows for two seconds will be caught some runs and missed
in others.

One consequence of following the assertion's rules: `waitFor` and the locator
after it do not compare the same way. `waitFor "Log Water"` wants that whole
label, case as written, while `tapText "log water"` matches a substring, folds
case, and also looks at the element's id. Write the label the way the screen
shows it and both are happy.

### Starting a flow from a known state

A flow inherits whatever the flow before it left behind: the session, the
onboarding it already dismissed, cached content, a half-filled form. That is
what makes a flow green on its own and red in the suite, and the report cannot
explain it. `launch` does not drop that state - on Android it goes through
`monkey`, which brings a running app to the front - and `install` keeps the data
of the previous install on purpose.

```json
{"do":"stopApp","value":"qa"},
{"do":"clearState","value":"qa"},
{"do":"launch","value":"qa"}
```

Both steps take the **variant name**, the way `launch` does, so the package and
the bundle id come from `yukti.config.json` and never from the flow file.

`stopApp` force-stops the app, and fails when the package named by the variant
is not installed - `am force-stop` answers the same way for a typo as for a real
package, so the step checks first.

`clearState` wipes the app's data and stops it, so the next step has to be a
`launch` - the app is not running after it. It also drops the runtime
permissions the app was granted, which is the point worth planning for: after it
the app is in its first-launch state, permission dialogs included, and a flow
that used to run past them has to dismiss them again.

`clearState` is Android-only for now (`pm clear`), and a flow that reaches it on
iOS fails rather than doing nothing: reinstall the app between flows there.
`stopApp` works on both, and on iOS an app that was not running is a warning,
not a failure - that is the state the step exists to reach. On iOS that warning
currently covers any refusal from `simctl`, a simulator that is not booted
included, so read a warning there as "not stopped, reason unknown". The iOS half
of both steps has not been exercised on a Mac.

`openUrl` opens a screen of the app under test by its key - `home`, `cart` -
instead of walking to it. It is the cheap way back to a known screen:
measured on one app on one Android 15 emulator, two runs each, an address reaches
the home screen in 3.7 and 5.2 seconds where `stopApp` + `launch` + `dismiss` +
`waitForId` takes 34.3 and 33.7 - and the address also resets the scroll position
of every tab, which tapping a tab does not. Those figures are for an app already
running; an address handed to a stopped app is a cold launch through the same
intent, with everything a launch puts on the screen.

What it promises is delivery, not arrival, and both halves of that matter. An
address the app does not route is still answered `Status: ok` by the device -
measured - and the app stays where it was. And arrival is later than the step:
`am start -W` returns once the launch has settled, which for an app already
running is at once, before the app has navigated. So the step after `openUrl` is
a `waitFor` or a `waitForId` for something on the screen you expect; an
`assertText` placed there races the navigation and goes red on a slow device with
nothing in the report to say why.

A flow says where to go and never in which environment. The address is built
here, not written in the step: the variant's `"urlBase"` (or one at the top level,
for a project whose builds share a scheme) plus the key. A project that wants its
paths in one place adds a `"urls"` table to the config and the key is looked up
there, so a route the app renames is one line to change instead of one per flow
that used it. The table is all or nothing: once it exists, a key that is not in it
stops the step, because falling back to the key as a path would open the address
nobody asked for and report success. Without a table, the key is the path, which
is where a project starts - and that path is what the results file records, so a
project that puts a `${VAR}` in it puts the substituted value there too.

```json
"urls": { "home": "home", "cart": "cart", "order": "orders/latest" },
"variants": {
  "qa":   { "urlBase": "myapp://" },
  "prod": { "urlBase": "myappprod://" }
}
```

The app it hands the address to is the one this run is driving, `$YUKTI_VARIANT`,
not an app named in the step: the address is the object here, the way the variant
is the object of `launch`. This has one sharp edge worth knowing. `$YUKTI_PLATFORM`
alone is enough for the rest of a run, and it is not enough for this step: with
no variant named, `openUrl` stops rather than guess. Worse, a variant left over
from an earlier run is not detected by anything - `up` and `launch` record which
variant they were for nowhere - so a stale `YUKTI_VARIANT=android-qa` on a device
that also carries the prod build will hand the address to the qa app, bring it to
the front, and let the rest of the flow assert against the other build in the same
UI. The console line names the package the address went to; read it when a run
looks right and measures wrong.

The package is named in the intent on purpose: a device carrying two builds of the
same app has two apps claiming one scheme, and an unaddressed intent opens a
chooser the flow would sit in front of until it timed out. On iOS `simctl openurl`
takes no bundle id, so there the system resolves the scheme and that hazard is
open; the iOS half has not been exercised on a Mac.

The address is printed whole, on purpose: when a step fails, the address it was
refused is the first thing a reader needs, and a step that hid half of it would be
a step that has to be re-run by hand to be understood. What the results file holds
is the step's own value - the key, when there is a `urls` table, and the path as
written when there is none, after `${VAR}` has been substituted into it. So the
rule is on the author, not on the tool: no secrets in an address. A one-time code
or a reset token belongs in a fixture the test sets up, not in a link a flow file
carries - and if one ever has to travel that way, it travels through a variable
whose value the run keeps out of the flow file, and the run log is then as
sensitive as the token in it.

### A block several flows share

`clearState` above makes every flow start from a clean app, which means every
flow has to sign in — and the sign-in is then copied into forty-five files and
edited in forty-five files the day that screen changes. `include` runs the steps
of another flow file in place:

```json
{ "do": "include", "value": "blocks/sign-in.json",
  "with": { "TEST_EMAIL": "beth@example.com" } }
```

The path is relative to the file that includes it, never to the directory the run
started in: a suite is moved and copied as one tree. The block is an ordinary flow
file and runs on its own — that is how it is debugged, and the recorder can write
it like any other flow.

`"with"` is read in the caller's scope and applies inside the block only, so the
same block signs in as a different account from a different flow, and
`${TEST_PASSWORD}` inside it still comes from the environment when the include
says nothing about it. A name that is in neither stops the flow before its first
step and says where to pass it.

Its steps are ordinary steps. They are numbered in sequence with the flow's own,
the console prints them the same way, and each is one testcase in the JUnit file.
That end-to-end number is not the number to look for in a file, so a failure adds
where the step was written - `cannot read the screen - see the error above (block
'blocks/sign-in.json', step 4)` - and a step of the flow itself that sits after a
block says `(step 2 of this flow file)`. Both the console line and the JUnit
failure carry it, whichever way the step failed.

A `${VARIABLE}` in the path expands like one in any other value: `${BLOCKS}/sign-in.json`
works, and an unset name stops the flow before its first step like any other.

Nesting stops at a block inside a block; a file that includes itself and a circle
of files fail before the run starts, with the chain printed - `a.json -> b.json ->
a.json`. The chain prints each name the way the include wrote it, so a block one
directory down closes the circle as `../a.json`, which is what it had to
write. A block reached through a symlink resolves its own
includes next to the real file, not next to the link.

Two flows whose files have the same name write the same JUnit file, because the
report is named after the file and not after its directory. Keep block names
distinct from flow names.

### A step that only runs sometimes

`"when"` on a step, or on an `include`, says under which conditions it runs:

```json
{"do":"tapText","value":"Accept","when":{"visible":"We use cookies"}},
{"do":"tapText","value":"Allow","when":{"platform":"android"}},
{"do":"include","value":"blocks/consent.json","when":{"notVisible":"Today"}}
```

`visible`, `notVisible`, `visibleId`, `notVisibleId`, `platform`; several in one
`"when"` all have to hold. On an `include` the condition is answered once, before
the block starts, and covers all of it: asking again at each step of the block
would run half of it as soon as its first step changed the screen - the dialog is
dismissed, so the rest of the block is skipped.

A condition that does not hold **skips** the step. The skip is loud: a `~` line
in the console naming the condition, and a `skipped` testcase in the JUnit file
with the same words. The step keeps its number - the numbering runs end to end
and a skipped step that gave its number away would move every step after it.

A condition that **cannot be answered** stops the flow. That is the whole reason
conditions and the negative assertions arrived together: an unreadable screen
answers "is this visible?" with "no", and a suite that accepts that answer
switches parts of itself off and stays green.

`visible` and `notVisible` ask the same oracle as `assertText` - perceivable
text, whole label, case as written - and `visibleId` / `notVisibleId` the exact
id. That is stricter than `tapText`, so a condition can skip a step `tapText`
would have found; the `~` line and the `skipped` entry are how you see it happen.

`platform` is `ios` or `android` against the platform of the run, and the skip
line names that platform: `skipped: platform 'android' (this run: ios)`. The run
says which platform it resolved and where that came from on its first line (see
"Which platform"), so the two lines together explain a step that did not run.

`optionalTapText` and `dismiss` stay as they are. What is new is that the same
thing can be written in the flow file, with the label in the file instead of in
the engine: `{"do":"tapText","value":"Skip","when":{"visible":"Skip"}}`.

## CI (every PR)

Copy `examples/ci/yukti-qa.yml` into the app repo's `.github/workflows/`, add
`TEST_EMAIL` / `TEST_PASSWORD` repo secrets, and each PR gets pass/fail + a
screenshots/video artifact. Add the `prod` variant to the matrix once a prod test account exists.

## Gotchas baked in (so you don't hit them)

- **Signing:** YUKTI ad-hoc signs the sim build so Firebase/keychain works. An
  unsigned build silently 401s every authenticated call (`-34018` keychain). Never
  build with `CODE_SIGNING_ALLOWED=NO`.
- **Node:** pinned to 22 — RN/Metro breaks on newer Node.
- **Device-only libs:** vendor SDKs without an arm64-sim slice (ML Kit, some BLE
  SDKs) break the link. `yukti scan` lists them; add to `excludeIosAutolink`.
- **Arch:** Apple-Silicon sims need arm64; YUKTI forces it.
- **Typing:** char-by-char (idb bulk-type drops characters).

## Prod testing note

Testing a `prod` build hits **live production data**. Use a dedicated prod test
account and keep destructive flows out of the prod matrix, or point them at a
disposable account.
