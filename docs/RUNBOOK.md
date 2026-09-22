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

## Which variant

| Variant | Backend | Firebase project | Test account |
| --- | --- | --- | --- |
| `dev` / `qa` | api-qa.example.com | your-qa-firebase-project | a **QA-tenant** account (e.g. qa-test@example.com) |
| `prod` | api.example.com | your-prod-firebase-project | a dedicated **prod test** account (not a real member) |

A QA account only exists in its own Firebase project — a prod account will 400 on
a QA build and vice-versa. Use the matching account per variant.

## Add a test case

Flows are JSON in `flows/`. Steps: `wait`, `screenshot`, `tap {x,y}`, `tapText`,
`optionalTapText`, `tapId`, `type`, `clearText {x,y}`, `pressKey`, `hideKeyboard`,
`scroll`, `scrollToText`, `dismiss`, `assertText`, `assertId`, `launch`. Coordinates are **points**
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

Ten more ways a flow stops, the first four of them typos that used to pass:

- a step name the runner does not know;
- a `"match"` value that is neither `exact` nor `contains`;
- a `"match"` key on a step that does not take one;
- a `wait` whose value is not a number - `sleep` refuses it;
- a `"value"` on a `hideKeyboard`, which has nothing to read one with;
- a `pressKey` naming a key the tool does not have;
- a `pressKey` asking for `back` on iOS, which has no Back key;
- a `clearText` whose coordinates land on something that is not a text field;
- a `clearText` whose coordinates land on a disabled field, or on one that
  cannot take focus, or a tap that leaves focus in a different field than the
  one named;
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
value carrying the character the runner separates its fields with. None of those
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

## CI (every PR)

Copy `.github/workflows/yukti-qa.yml` into the app repo, add `TEST_EMAIL` /
`TEST_PASSWORD` repo secrets, and each PR gets pass/fail + a screenshots/video
artifact. Add the `prod` variant to the matrix once a prod test account exists.

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
