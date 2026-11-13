#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Checks of the engine that need no device. Each case builds its own flow files
# in a fresh directory, runs yukti on them and asserts what came out: the exit
# status AND a piece of the output. A case that asserted the status alone would
# pass on any refusal, including one for a reason the case never meant.
#
# Written for the bash a Mac ships (/bin/bash 3.2) as well as for the CI runner:
# no mapfile, no associative arrays, no GNU-only flags.
#
#   tests/run.sh            run every case, exit 1 if any failed
#   KEEP=1 tests/run.sh     the same, and leave the case directories behind
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # no -e: one failed case must not hide the ones after it

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YUKTI="$ROOT/yukti"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/yukti-tests.XXXXXX")" || exit 1
[ -n "$WORK" ] || { echo "no temporary directory for the cases" >&2; exit 1; }
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

pass=0; fail=0; case_dir=""

# A fresh directory per case: a file left by one case cannot satisfy another.
new_case(){ case_dir="$WORK/$1"; mkdir -p "$case_dir"; }

# step <json> - one step of a flow file, written as JSON.
# flow_file <path> <step>... - a flow file with these steps.
flow_file(){ local f="$1" sep="" s; shift
  { printf '{ "name": "%s", "steps": [' "$(basename "$f" .json)"
    for s in "$@"; do printf '%s\n  %s' "$sep" "$s"; sep=","; done
    printf '\n] }\n'; } > "$f"; }

# chain <dir> <n> - flow.json includes b1.json, b1 includes b2, ... bn. Every
# file carries one wait of its own, so a flow that builds has n+1 steps: the
# count proves the builder went all the way down, not just that it said yes.
chain(){ local d="$1" n="$2" i
  flow_file "$d/flow.json" '{ "do": "wait", "value": "1" }' '{ "do": "include", "value": "b1.json" }'
  i=1
  while [ "$i" -lt "$n" ]; do
    flow_file "$d/b$i.json" '{ "do": "wait", "value": "1" }' "{ \"do\": \"include\", \"value\": \"b$((i + 1)).json\" }"
    i=$((i + 1))
  done
  flow_file "$d/b$n.json" '{ "do": "wait", "value": "1" }'; }

# chain_names <n> - the chain as the engine prints it: flow.json -> b1.json ...
chain_names(){ local n="$1" i=1 s="flow.json"
  while [ "$i" -le "$n" ]; do s="$s -> b$i.json"; i=$((i + 1)); done
  printf '%s' "$s"; }

# expect <name> <status> <text> <command...> - run the command, compare the
# status and look for the text in what it printed (colour codes removed).
expect(){ local name="$1" want="$2" text="$3" out st; shift 3
  out="$("$@" 2>&1)"; st=$?
  out="$(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g')"
  if [ "$st" -eq "$want" ] && case "$out" in *"$text"*) true;; *) false;; esac; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL %s\n     wanted status %s and "%s"\n     got status %s:\n%s\n' \
      "$name" "$want" "$text" "$st" "$(printf '%s' "$out" | sed 's/^/       /')"
  fi; }

check(){ "$YUKTI" flow --check "$1"; }

# ── include depth (#93) ──────────────────────────────────────────────────────
new_case include-3
chain "$case_dir" 3
expect "include: three blocks deep builds" 0 " - 4 steps" check "$case_dir/flow.json"

new_case include-8
chain "$case_dir" 8
expect "include: eight blocks deep builds" 0 " - 9 steps" check "$case_dir/flow.json"

new_case include-9
chain "$case_dir" 9
expect "include: a ninth block is refused with the chain" 1 \
  "includes may go 8 blocks deep - 'b9.json' would be block 9: $(chain_names 9)" check "$case_dir/flow.json"

new_case include-self
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json" }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b1.json" }'
expect "include: a block that includes itself is refused" 1 \
  "a block cannot include itself, directly or in a circle: flow.json -> b1.json -> b1.json" \
  check "$case_dir/flow.json"

new_case include-circle
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json" }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b1.json" }'
expect "include: a circle of blocks is refused" 1 \
  "a block cannot include itself, directly or in a circle: flow.json -> b1.json -> b2.json -> b1.json" \
  check "$case_dir/flow.json"

# A parameter passed at the top reaches the fourth block. The variable is not
# in the environment, and the builder refuses a variable it cannot fill, so the
# flow builds only if the value travelled down through every level.
new_case include-with
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json", "with": { "YUKTI_TEST_DEEP": "Today" } }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b3.json" }'
flow_file "$case_dir/b3.json" '{ "do": "include", "value": "b4.json" }'
flow_file "$case_dir/b4.json" '{ "do": "waitFor", "value": "${YUKTI_TEST_DEEP}" }'
expect "include: a parameter reaches the fourth block" 0 " - 1 steps" \
  env -u YUKTI_TEST_DEEP "$YUKTI" flow --check "$case_dir/flow.json"

# The name arriving is not the value arriving. A value with the runner's field
# separator in it passes the include - parameters are not checked for it there
# - and is refused only by the step that uses it, so this refusal, named after
# the fourth block, is the value itself reaching the bottom.
new_case include-with-value
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json", "with": { "YUKTI_TEST_DEEP": "a\u001fb" } }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b3.json" }'
flow_file "$case_dir/b3.json" '{ "do": "include", "value": "b4.json" }'
flow_file "$case_dir/b4.json" '{ "do": "waitFor", "value": "${YUKTI_TEST_DEEP}" }'
expect "include: the value of a parameter reaches the fourth block" 1 \
  "step 1 'waitFor' of block 'b4.json': \"value\" contains a character the runner separates fields with" \
  env -u YUKTI_TEST_DEEP "$YUKTI" flow --check "$case_dir/flow.json"

# ── no HOME in the environment (#58) ─────────────────────────────────────────
# Under set -u a bare $HOME at the top of the script stopped it before anything
# ran, help and --check included, with "HOME: unbound variable".
new_case no-home
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "1" }'
expect "no HOME: help runs" 0 "yukti v" env -i PATH="$PATH" "$YUKTI" help
expect "no HOME: flow --check runs" 0 " - 1 steps" env -i PATH="$PATH" "$YUKTI" flow --check "$case_dir/flow.json"

# ── a failing step on a device (#94) ─────────────────────────────────────────
# The device is tests/fake-sdk/platform-tools/adb, put first in PATH through
# ANDROID_HOME (the engine derives its SDK path from it). Each case gets its own
# directory for the fake, the results and $TMPDIR.
dev_case(){ new_case "$1"; mkdir -p "$case_dir/adb" "$case_dir/res" "$case_dir/tmp"; }

# screen <file> <node>... - a uiautomator dump holding these nodes.
screen(){ local f="$1" n; shift
  { printf '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hierarchy rotation="0">'
    for n in "$@"; do printf '%s' "$n"; done
    printf '</hierarchy>\n'; } > "$f"; }

# node <class> <resource-id> <text> [focused] [password] - one node of a dump.
node(){ printf '<node index="0" text="%s" resource-id="com.example:id/%s" class="android.widget.%s" package="com.example" content-desc="%s" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="%s" scrollable="false" long-clickable="false" password="%s" selected="false" bounds="[0,%d][1080,%d]" />' \
  "$3" "$2" "$1" "$3" "${4:-false}" "${5:-false}" "$(node_y "$2")" "$(( $(node_y "$2") + 120 ))"; }
# Each node its own band, the same on every run: the place comes from the id.
node_y(){ local y; y="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; printf '%d' $(( (y % 15) * 140 + 100 )); }

# run_flow <flow> [VAR=value...] - the flow against the fake, output kept in
# $case_dir/out and the status in $run_status.
run_flow(){ local f="$1"; shift
  env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
    FAKE_ADB_DIR="$case_dir/adb" YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" "$@" \
    "$YUKTI" flow "$f" > "$case_dir/out" 2>&1
  run_status=$?
  sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"; }

# Assertions for one case collect into $why; verdict prints it.
begin(){ case_name="$1"; why=""; }
no(){ why="$why
     $*"; }
status_is(){ [ "$run_status" -eq "$1" ] || no "status $run_status, wanted $1"; }
file_full(){ [ -s "$case_dir/$1" ] || no "$1 is missing or empty"; }
file_absent(){ [ ! -e "$case_dir/$1" ] || no "$1 exists and should not"; }
has(){ grep -qF -- "$2" "$case_dir/$1" 2>/dev/null || no "$1 lacks: $2"; }
lacks(){ ! grep -qiF -- "$2" "$case_dir/$1" 2>/dev/null || no "$1 holds: $2"; }
# The fake was asked something - otherwise a case that passed against a real
# adb found first in PATH would look exactly the same.
fake_used(){ [ -s "$case_dir/adb/log" ] || no "the fake adb was never called"; }
verdict(){ if [ -z "$why" ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$case_name"
  else fail=$((fail + 1)); printf 'FAIL %s%s\n     output:\n%s\n' "$case_name" "$why" "$(sed 's/^/       /' "$case_dir/out.txt" 2>/dev/null)"; fi; }

# ── a flow variable named like an internal one (#101) ────────────────────────
# The console colours used to be the shell variables R, B, G, Y and E: an
# exported E reached the flow as an escape sequence. Any other variable the
# script assigns did the same - CONFIG with the config file's name, PY with the
# path of python, HELD_TREE emptied. The fake screen holds the user's value, so
# the assertion passes only if the value arrived as exported.
for v in E R B G Y CONFIG PY NODE22 UIA2_PORT HELPER_WHY HELD_TREE; do
  dev_case colour-name-$v
  screen "$case_dir/adb/dump-1.xml" "$(node TextView greeting myvalue)"
  flow_file "$case_dir/flow.json" "{ \"do\": \"assertText\", \"value\": \"\${$v}\" }"
  run_flow "$case_dir/flow.json" $v=myvalue
  begin "a flow variable named $v keeps the value the user exported"
  status_is 0; fake_used; has out.txt "assert (exact): 'myvalue' on screen"
  verdict
done

MARK="Synthetic marker text"   # on every screen, never secret: a mask that
                               # blanked the whole tree must not pass

dev_case capture-missing-id
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)" "$(node TextView marker "$MARK")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "capture: a failed step leaves its screen and its tree"
status_is 1; fake_used
file_full res/flow-fail.png; file_full res/flow-fail.xml
has res/flow-fail.xml "$MARK"
has res/flow.xml "not on screen"; has res/flow.xml "screen: flow-fail.png"; has res/flow.xml "tree: flow-fail.xml"
verdict

# What a flow typed is masked in the tree, and so is a password field however
# it arrived there. The typed value carries an & and a quote: the dump writes
# the & escaped and puts the value in '...' because of the quote, and a mask
# that looked only for the raw text, or only inside "...", would miss it. The
# second field holds its hint and a piece of an earlier attempt - what a React
# Native input showed after a retyped value.
LEFTOVER="<node index=\"0\" text='Type a message...beth&amp;co\"x@exa' resource-id=\"com.example:id/chat\" class=\"android.widget.EditText\" package=\"com.example\" content-desc=\"\" focused=\"false\" password=\"false\" bounds=\"[0,1900][1080,2000]\" />"
dev_case capture-mask
screen "$case_dir/adb/dump-1.xml" "$(node EditText email @TYPED@ true)" "$LEFTOVER" \
  "$(node EditText pin 'Static&amp;pin&quot;9' false true)" "$(node TextView marker "$MARK")"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_EMAIL}" }' \
  '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json" TEST_EMAIL='beth&co"x@example.invalid'
begin "capture: typed text and password fields are masked in the tree"
status_is 1; fake_used; file_full res/flow-fail.xml
has res/flow-fail.xml "$MARK"
lacks res/flow-fail.xml 'beth&amp;co'; lacks res/flow-fail.xml '@example.invalid'; lacks res/flow-fail.xml 'Static&amp;pin'
lacks res/flow-fail.xml 'co"x@exa'; has res/flow-fail.xml 'resource-id="com.example:id/chat"'
verdict

# The step that types is the one that fails: its value is only in the record
# of the running step. Every burst of keys loses its last character, so the
# field ends up holding the value with gaps - what an emulator under load
# leaves - which a mask that matched whole values would let through.
dev_case capture-type-fails
screen "$case_dir/adb/dump-1.xml" "$(node EditText password @TYPED@ true)" "$(node TextView marker "$MARK")"
: > "$case_dir/adb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_PASSWORD}" }'
run_flow "$case_dir/flow.json" TEST_PASSWORD='Pa&ss"w0rd!Long'
begin "capture: a failed type step is masked, gaps included"
status_is 1; fake_used; file_full res/flow-fail.xml
has res/flow-fail.xml "$MARK"
lacks res/flow-fail.xml 'Pa&amp;ss'; lacks res/flow-fail.xml 'wrd!Lon'
verdict

dev_case capture-screencap-fails
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
echo fail > "$case_dir/adb/screencap"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "capture: a screenshot that fails still leaves the result and the reason"
status_is 1; fake_used; file_absent res/flow-fail.png; file_full res/flow-fail.xml
has res/flow.xml "not on screen"; has res/flow.xml "screen not captured"
verdict

dev_case capture-screencap-hangs
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
echo hang > "$case_dir/adb/screencap"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
t0=$SECONDS; run_flow "$case_dir/flow.json"; took=$((SECONDS - t0))
begin "capture: a screenshot that never answers is given up on"
status_is 1; fake_used
[ "$took" -lt 40 ] || no "the run took ${took}s"
has res/flow.xml "not on screen"; has res/flow.xml "screen not captured"
verdict

# A tap by coordinates reads no tree. The tree that is kept was read by the
# step before it, and the result says so instead of passing it off as the
# screen of the failure.
dev_case capture-older-tree
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
: > "$case_dir/adb/tap-fails"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }' '{ "do": "tap", "x": 10, "y": 10 }'
run_flow "$case_dir/flow.json"
begin "capture: a tree read by an earlier step is named as such"
status_is 1; fake_used
has res/flow.xml "tree: flow-fail.xml (read by step 1)"
verdict

# A condition that cannot read the screen stops the run before its step is
# recorded: the failure lands on "00 flow", and the screen is still taken.
dev_case capture-when-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "0" }' \
  '{ "do": "tap", "x": 10, "y": 10, "when": { "visibleId": "title" } }'
run_flow "$case_dir/flow.json"
begin "capture: a condition that cannot read the screen still leaves the screen"
status_is 1; fake_used; file_full res/flow-fail.png
has res/flow.xml 'name="00 flow"'; has res/flow.xml "screen: flow-fail.png"; has res/flow.xml "tree: none"
verdict

dev_case capture-pass
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "capture: a flow that passes leaves no failure files"
status_is 0; fake_used; file_full res/flow.xml
file_absent res/flow-fail.png; file_absent res/flow-fail.xml
verdict

# A step of a block four levels down is named with its block in the result.
dev_case capture-deep-block
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json" }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b3.json" }'
flow_file "$case_dir/b3.json" '{ "do": "include", "value": "b4.json" }'
flow_file "$case_dir/b4.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "results: a step four blocks down is named with its block"
status_is 1; fake_used; has res/flow.xml "[b4.json] waitForId missing"
verdict

# And a flow on a device with no HOME: the SDK comes from ANDROID_HOME, the
# helper's cache from the temporary directory.
dev_case no-home-run
screen "$case_dir/adb/dump-1.xml" "$(node TextView greeting Hello)"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Hello" }'
expect "no HOME: a flow runs on a device" 0 "assert (exact): 'Hello' on screen" \
  env -u HOME -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
    FAKE_ADB_DIR="$case_dir/adb" YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" "$YUKTI" flow "$case_dir/flow.json"

# ── fix the app, or restart the device (#96) ─────────────────────────────────
# What the engine knows for sure is the device's - a screen that could not be
# read, a screenshot not taken - and is a JUnit <error>. Everything else stays
# a <failure>. The exit status is 1 either way.
red_is(){ has res/flow.xml "<$1 message="; has res/flow.xml "type=\"$2\""
  has res/flow.xml "failures=\"$3\" errors=\"$4\""; }

dev_case junit-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "junit: a screen that cannot be read is an error"
status_is 1; fake_used; red_is error DeviceError 0 1
verdict

# One read of three fails, the next ones work, the element is not there: the
# step failed on what it saw. A mark left by the bad read must not decide.
dev_case junit-one-bad-read
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
cp "$case_dir/adb/dump-1.xml" "$case_dir/adb/dump-2.xml"; cp "$case_dir/adb/dump-1.xml" "$case_dir/adb/dump-3.xml"
screen "$case_dir/adb/dump-4.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 3 }'
run_flow "$case_dir/flow.json"
begin "junit: a missed read does not make a missing element an error"
status_is 1; fake_used; red_is failure StepFailed 1 0; has res/flow.xml "not on screen"
verdict

dev_case junit-missing
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "junit: a missing element is a failure"
status_is 1; fake_used; red_is failure StepFailed 1 0
verdict

dev_case junit-screenshot
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
echo fail > "$case_dir/adb/screencap"
flow_file "$case_dir/flow.json" '{ "do": "screenshot", "value": "home" }'
run_flow "$case_dir/flow.json"
begin "junit: a screenshot the device did not take is an error"
status_is 1; fake_used; red_is error DeviceError 0 1; has res/flow.xml "screenshot failed"
verdict

# A name the engine refuses is the author's mistake, not the device's.
dev_case junit-screenshot-name
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "screenshot", "value": "../home" }'
run_flow "$case_dir/flow.json"
begin "junit: a screenshot name the engine refuses is a failure"
status_is 1; red_is failure StepFailed 1 0; has res/flow.xml "must not contain"
verdict

dev_case junit-when-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "0" }' \
  '{ "do": "tap", "x": 10, "y": 10, "when": { "visibleId": "title" } }'
run_flow "$case_dir/flow.json"
begin "junit: a condition that cannot read the screen is an error on 00 flow"
status_is 1; fake_used; red_is error FlowError 0 1; has res/flow.xml 'name="00 flow"'
verdict

dev_case junit-bad-file
printf '{ "steps": [' > "$case_dir/flow.json"
run_flow "$case_dir/flow.json"
begin "junit: a flow file that does not build is a failure"
status_is 1; red_is failure FlowFailed 1 0
verdict

# ── how often type and clear read the screen (#106) ──────────────────────────
# A read of the screen costs seconds on a device, so the count of reads is what
# these cases assert, beside the outcome. The fake counts them in `dumps` (adb)
# and `describes` (idb).
VALUE='synthetic.value+22@x.y'   # 22 characters, three bursts of eight

# field <id> <focused> <x1,y1,x2,y2> [text] - an EditText at a given place.
field(){ printf '<node index="0" text="%s" resource-id="com.example:id/%s" class="android.widget.EditText" package="com.example" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="%s" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[%s][%s]" />' \
  "${4:-@TYPED@}" "$1" "$2" "$(printf '%s' "$3" | cut -d, -f1-2)" "$(printf '%s' "$3" | cut -d, -f3-4)"; }
reads_are(){ local got; got="$(cat "$case_dir/adb/dumps" 2>/dev/null || echo 0)"
  [ "$got" = "$1" ] || no "the screen was read $got times, wanted $1"; }
typed_is(){ [ "$(cat "$case_dir/adb/typed" 2>/dev/null)" = "$1" ] || no "the field holds '$(cat "$case_dir/adb/typed" 2>/dev/null)', wanted '$1'"; }

dev_case type-one-read
screen "$case_dir/adb/dump-1.xml" "$(field email true 100,500,900,600)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_flow "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type: three bursts, the field read once before and once after"
status_is 0; fake_used; reads_are 2; typed_is "$VALUE"
lacks out.txt "lost characters"
verdict

dev_case type-retry
screen "$case_dir/adb/dump-1.xml" "$(field email true 100,500,900,600)"
printf '1' > "$case_dir/adb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_flow "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type: a burst that lost a character is caught after the last one and typed again"
status_is 0; typed_is "$VALUE"
has out.txt "attempt 1 lost characters"; has out.txt "22 characters arrived on attempt 2"
verdict

# A value with a " in it: uiautomator quotes such an attribute with ' (the fake
# does what the device does), and a reader of "..." alone saw no text at all -
# "arrived 0 of 16 characters" after three attempts (#100).
dev_case type-double-quote
screen "$case_dir/adb/dump-1.xml" "$(field email true 100,500,900,600)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_flow "$case_dir/flow.json" TEST_VALUE='Qa&Probe"mask 42'
begin "type: a value with a double quote is read back from its single-quoted attribute"
status_is 0; reads_are 2; typed_is 'Qa&Probe"mask 42'; lacks out.txt "lost characters"
verdict

dev_case assert-double-quote
screen "$case_dir/adb/dump-1.xml" "$(node TextView quote x | sed "s/ text=\"x\"/ text='Say \"hi\"'/; s/ content-desc=\"x\"/ content-desc=''/")"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Say \"hi\"" }' '{ "do": "tapText", "value": "Say \"hi\"" }'
run_flow "$case_dir/flow.json"
begin "assertText and tapText: a label with a double quote is found in its single-quoted attribute"
status_is 0; has out.txt "assert (exact): 'Say \"hi\"' on screen"; has adb/log "input tap"
verdict

# "shows" (#128): a field that filters what is typed holds less than was sent.
dev_case type-shows
screen "$case_dir/adb/dump-1.xml" "$(field amount true 100,500,900,600)"
printf '0123456789' > "$case_dir/adb/filter"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!", "shows": "12" }' '{ "do": "assertText", "value": "12" }'
run_flow "$case_dir/flow.json"
begin "type with shows: a digits-only field drops the letters, the step is green and assertText checks the field"
status_is 0; fake_used; reads_are 3; typed_is "12"
lacks out.txt "lost characters"
verdict

dev_case type-shows-own-text
printf '7' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field amount true 100,500,900,600)"
printf '0123456789' > "$case_dir/adb/filter"; printf '1' > "$case_dir/adb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!5", "shows": "125" }'
run_flow "$case_dir/flow.json"
begin "type with shows: the field's own text is typed again in front of the value on a retry"
status_is 0; typed_is "7125"
has out.txt "the field shows the expected 3 characters on attempt 2"
verdict

dev_case type-shows-retry
screen "$case_dir/adb/dump-1.xml" "$(field amount true 100,500,900,600)"
printf '0123456789' > "$case_dir/adb/filter"; printf '1' > "$case_dir/adb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!5", "shows": "125" }'
run_flow "$case_dir/flow.json"
begin "type with shows: a lost character is still caught and the value typed again"
status_is 0; typed_is "125"
has out.txt "attempt 1 lost characters"; has out.txt "the field shows the expected 3 characters on attempt 2"
verdict

dev_case type-shows-fails
screen "$case_dir/adb/dump-1.xml" "$(field amount true 100,500,900,600)"
printf '0123456789' > "$case_dir/adb/filter"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!", "shows": "13" }'
run_flow "$case_dir/flow.json"
begin "type with shows: a field that shows something else fails with counts, not the values"
status_is 1
has out.txt 'the field does not show what "shows" expects after 3 attempts (it holds 2 characters, "shows" has 2)'
lacks out.txt "12a!"
verdict

dev_case type-filter-no-shows
screen "$case_dir/adb/dump-1.xml" "$(field amount true 100,500,900,600)"
printf '0123456789' > "$case_dir/adb/filter"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!" }'
run_flow "$case_dir/flow.json"
begin "type without shows: a field that drops characters still fails as before"
status_is 1; has out.txt "arrived 2 of 4 characters after 3 attempts"
verdict

dev_case clear-two-reads
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,500,900,600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,500,900,600)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: one read finds the field, one after the delete proves it empty"
status_is 0; fake_used; reads_are 2; typed_is ""
has out.txt "field empty at 500,550"
verdict

dev_case clear-hint
printf 'old text' > "$case_dir/adb/typed"; printf 'Email' > "$case_dir/adb/hint"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,500,900,600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,500,900,600)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a field showing its hint takes a third read to be called empty"
status_is 0; reads_are 3; typed_is ""
has out.txt "field empty at 500,550"
verdict

dev_case clear-leftover
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,500,900,600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,500,900,600 'left over')"
screen "$case_dir/adb/dump-3.xml" "$(field email true 100,500,900,600 'left ove')"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: text the probing delete still shortens is not called empty"
status_is 1; reads_are 3
has out.txt "the field still holds text after select-all and delete"
verdict

dev_case clear-moved
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,900,900,1000)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: the field the keyboard moved up is still the field"
status_is 0; reads_are 2; typed_is ""
has out.txt "the field moved to 100 900 900 1000"
verdict

# An id that another row shares does not settle it (#165): the shape has to.
dev_case clear-other-shape
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)" "$(field email false 100,1700,900,1800 Other)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 0,300,1080,420)" "$(field email false 100,1700,900,1800 Other)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a focused field of another width, with an id another row shares, is another field"
status_is 1; reads_are 2
has out.txt "focus is in a different field than the one at 500,1550"
verdict

dev_case clear-other-id
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field search true 100,900,900,1000)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a focused field with another id is another field"
status_is 1
has out.txt "focus is in a different field (com.example:id/search)"
verdict

# The node a keyboard moves keeps its id; one that arrives without the id the
# field had is another field, whatever its shape.
dev_case clear-id-lost
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,900,900,1000 | sed 's/com.example:id\/email//')"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a moved field that lost its id is another field"
status_is 1; reads_are 2
has out.txt "focus is in a different field than the one at 500,1550"
verdict

# Another field held focus before the tap: a tap that does not take would leave
# the keys to that field, so it is asked for before any key - and left alone.
dev_case clear-focus-stays
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600 Mine)" "$(field name true 100,300,900,400)"
screen "$case_dir/adb/dump-2.xml" "$(field email false 100,1500,900,1600 Mine)" "$(field name true 100,300,900,400)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: focus left in another field stops the step before any key"
status_is 1; reads_are 2; typed_is "old text"
has out.txt "focus is in a different field (com.example:id/name)"
lacks adb/log "keycombination"
verdict

dev_case clear-focus-moves
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)" "$(field name true 100,300,900,400 Name)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,1500,900,1600)" "$(field name false 100,300,900,400 Name)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: focus taken from another field costs one read more, and clears"
status_is 0; reads_are 3; typed_is ""
verdict

# #165. The field is taken by its id when no other node on the screen carries
# it, before the tap and after it: a search field that drops its clear button
# with its text is wider when empty, and a form that scrolls when focus moves
# from the field above carries the field to a new place.
dev_case clear-width-grows
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field search false 150,500,934,600)"
screen "$case_dir/adb/dump-2.xml" "$(field search true 150,500,1004,600)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "search" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a field with an id of its own that grows wider when emptied is still the field"
status_is 0; reads_are 2; typed_is ""
has out.txt "field empty at 542,550"
verdict

dev_case clear-width-grows-coords
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field search false 150,1150,934,1250)"
screen "$case_dir/adb/dump-2.xml" "$(field search true 150,1150,1004,1250)"
flow_file "$case_dir/flow.json" '{ "do": "clearText", "x": "50%", "y": "50%" }'
run_flow "$case_dir/flow.json"
begin "clearText by coordinates: a field of another width is still another field"
status_is 1; reads_are 2
has out.txt "focus is in a different field than the one at 540,1200"
verdict

dev_case clear-focus-moves-scrolled
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600 Mine)" "$(field name true 100,300,900,400 Name)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,900,900,1000)" "$(field name false 100,-300,900,-200 Name)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: focus taken from the field above, the form scrolled - the field with its own id is cleared"
status_is 0; reads_are 3; typed_is ""
has out.txt "the field moved to 100 900 900 1000"
verdict

dev_case clear-focus-moves-scrolled-shared-id
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600 Mine)" "$(field email false 100,1700,900,1800 Other)" "$(field name true 100,300,900,400 Name)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,900,900,1000)" "$(field email false 100,1100,900,1200 Other)" "$(field name false 100,-300,900,-200 Name)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: focus moved, the form scrolled, the id is shared - stopped before any key"
status_is 1; reads_are 2; typed_is "old text"
has out.txt "focus is in a different field than the one at 500,1550"
lacks adb/log "keycombination"
verdict

# iOS: the fake idb first in PATH, the simulator id where the engine keeps it.
ios_case(){ new_case "$1"; mkdir -p "$case_dir/idb" "$case_dir/res" "$case_dir/tmp"
  printf 'FAKE-UDID' > "$case_dir/tmp/yukti-udid"; }
# tree <file> <element>... - an idb describe-all answer.
tree(){ local f="$1" e sep=""; shift
  { printf '['; for e in "$@"; do printf '%s%s' "$sep" "$e"; sep=","; done; printf ']\n'; } > "$f"; }
# itext <id> <y> [value] - a text field 300 wide and 40 high at x 40.
itext(){ printf '{"type":"TextField","role_description":"text field","AXUniqueId":"%s","AXLabel":"","AXValue":%s,"frame":{"x":40,"y":%s,"width":300,"height":40}}' \
  "$1" "${3:-\"@TYPED@\"}" "$2"; }
run_ios(){ local f="$1"; shift
  env -u YUKTI_VARIANT -u YUKTI_CONFIG PATH="$ROOT/tests/fake-sdk/idb-bin:$PATH" YUKTI_PLATFORM=ios FAKE_IDB_DIR="$case_dir/idb" \
    YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" "$@" \
    "$YUKTI" flow "$f" > "$case_dir/out" 2>&1
  run_status=$?
  sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"; }
ireads_are(){ local got; got="$(cat "$case_dir/idb/describes" 2>/dev/null || echo 0)"
  [ "$got" = "$1" ] || no "the screen was read $got times, wanted $1"; }
ityped_is(){ [ "$(cat "$case_dir/idb/typed" 2>/dev/null)" = "$1" ] || no "the field holds '$(cat "$case_dir/idb/typed" 2>/dev/null)', wanted '$1'"; }
bursts_are(){ local got; got="$(grep -c '^ui text ' "$case_dir/idb/log" 2>/dev/null)"
  [ "$got" = "$1" ] || no "$got calls to type, wanted $1"; }

ios_case ios-type
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a key at a time, the fields read once before and once after"
status_is 0; ireads_are 2; bursts_are 22; ityped_is "$VALUE"
verdict

ios_case ios-type-retry
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
printf '1' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a lost character is deleted back out and the value typed again"
status_is 0; ityped_is "$VALUE"; bursts_are 44
has out.txt "22 characters arrived on attempt 2"
verdict

ios_case ios-type-fails
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
printf '' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a field that keeps losing characters fails with counts, not the value"
status_is 1; has out.txt "arrived 0 of 22 characters after 3 attempts"
lacks out.txt "$VALUE"
verdict

ios_case ios-type-unchanged
tree "$case_dir/idb/desc-1.json" "$(itext email 200 "\"$VALUE\"")"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a field that already held the value is not where the keys went"
status_is 1; has out.txt "arrived 0 of 22 characters after 3 attempts"
verdict

# Between the two reads the layout moved up - the keyboard, or a scroll to the
# caret - and a field of the same shape above holds text of its own. The field
# typed into is the one in the same place in the column, not the neighbour.
ios_case ios-type-shifted
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')" "$(itext email 200)"
tree "$case_dir/idb/desc-2.json" "$(itext name 50 '"Ada"')" "$(itext email 150)"
printf '1' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a layout that moved between the reads still finds the field"
status_is 0; ityped_is "$VALUE"
has out.txt "22 characters arrived on attempt 2"
verdict

ios_case ios-type-shifted-lost
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')" "$(itext email 200)"
tree "$case_dir/idb/desc-2.json" "$(itext name 50 '"Ada"')" "$(itext email 150)"
printf '' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a moved neighbour's own text is not counted as arrived"
status_is 1; has out.txt "arrived 0 of 22 characters after 3 attempts"
verdict

ios_case ios-type-secure
tree "$case_dir/idb/desc-1.json" "$(itext pin 200 '"@DOTS@"')"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a secure field is compared as dots"
status_is 0; ireads_are 2; ityped_is "$VALUE"
lacks out.txt "lost characters"
verdict

ios_case ios-type-placeholder
printf 'Email' > "$case_dir/idb/hint"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a placeholder the value replaced is not text of the field's own"
status_is 0; ireads_are 2; ityped_is "$VALUE"
lacks out.txt "lost characters"
verdict

ios_case ios-type-placeholder-lost
printf 'Email' > "$case_dir/idb/hint"; printf '1' > "$case_dir/idb/lossy"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a key lost in a field with a placeholder is typed again"
status_is 0; ityped_is "$VALUE"
has out.txt "22 characters arrived on attempt 2"
verdict

ios_case ios-type-shows
tree "$case_dir/idb/desc-1.json" "$(itext amount 200)"
printf '0123456789' > "$case_dir/idb/filter"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!", "shows": "12" }'
run_ios "$case_dir/flow.json"
begin "type with shows on iOS: a digits-only field drops the letters and the step is green"
status_is 0; ireads_are 2; bursts_are 4; ityped_is "12"
verdict

ios_case ios-type-shows-fails
tree "$case_dir/idb/desc-1.json" "$(itext amount 200)"
printf '0123456789' > "$case_dir/idb/filter"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!", "shows": "13" }'
run_ios "$case_dir/flow.json"
begin "type with shows on iOS: a field that shows something else fails with counts"
status_is 1
has out.txt 'the field does not show what "shows" expects after 3 attempts (it holds 2 characters, "shows" has 2)'
lacks out.txt "12a!"
verdict

ios_case ios-clear
printf 'old text' > "$case_dir/idb/typed"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: one read finds the field, one proves it empty"
status_is 0; ireads_are 2; ityped_is ""
has out.txt "field empty at 190,220"
verdict

# A plain field shows its placeholder as its value while it is empty, as a
# secure one does. idb names no placeholder, so one digit tells the two apart.
ios_case ios-clear-placeholder-empty
printf 'Email' > "$case_dir/idb/hint"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: an empty plain field's placeholder is not text left behind"
status_is 0; ireads_are 4; ityped_is ""
has out.txt "field empty at 190,220 (it shows its placeholder)"
has idb/log "ui text --udid FAKE-UDID 1"
verdict

ios_case ios-clear-placeholder
printf 'Email' > "$case_dir/idb/hint"; printf 'old text' > "$case_dir/idb/typed"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: a plain field is empty once its text gives way to the placeholder"
status_is 0; ityped_is ""
has out.txt "field empty at 190,220 (it shows its placeholder)"
verdict

# deletes_are <n> - how many delete keys reached the fake.
deletes_are(){ local got; got="$(grep -c 'ui key --udid FAKE-UDID 42' "$case_dir/idb/log" 2>/dev/null)"
  [ "$got" = "$1" ] || no "$got deletes, wanted $1"; }

ios_case ios-clear-placeholder-text-left
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"zqx old"')"
tree "$case_dir/idb/desc-2.json" "$(itext email 200 '"zqx"')"
tree "$case_dir/idb/desc-3.json" "$(itext email 200 '"zqx1"')"
tree "$case_dir/idb/desc-4.json" "$(itext email 200 '"zqx"')"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: text the deletes missed is not taken for a placeholder, and the digit goes again"
status_is 1; deletes_are 8
has out.txt "the field still holds text after 7 deletes"
lacks out.txt "zqx"
verdict

ios_case ios-clear-placeholder-no-digit
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"Email"')"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: a value no key changes is not called a placeholder"
status_is 1; deletes_are 5
has out.txt "took no digit to tell"
verdict

ios_case ios-clear-placeholder-digit-stays
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"Email"')"
tree "$case_dir/idb/desc-3.json" "$(itext email 200 '"1"')"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: a digit its delete did not take back stops the step"
status_is 1
has out.txt "the digit typed to tell a placeholder from text is still in the field"
verdict

# isecure <id> <y> - a secure text field: dots while it holds text, its
# placeholder (the hint) while it is empty, as a simulator reports one.
isecure(){ printf '{"type":"TextField","role_description":"secure text field","AXUniqueId":"%s","AXLabel":"","AXValue":"@SECURE@","frame":{"x":40,"y":%s,"width":300,"height":40}}' \
  "$1" "$2"; }

ios_case ios-clear-secure-empty
printf 'Password' > "$case_dir/idb/hint"
tree "$case_dir/idb/desc-1.json" "$(isecure password 200)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "password" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: an empty secure field's placeholder is not text to delete"
status_is 0; ityped_is ""
has out.txt "the field was already empty"
lacks idb/log "ui key"
verdict

ios_case ios-clear-secure
printf 'Password' > "$case_dir/idb/hint"; printf 'old pass' > "$case_dir/idb/typed"
tree "$case_dir/idb/desc-1.json" "$(isecure password 200)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "password" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: a secure field is empty once its dots give way to the placeholder"
status_is 0; ityped_is ""
has out.txt "field empty at 190,220"
verdict

# hideKeyboard on Android (#151). Back goes first while the input method says
# the keyboard is up: the IME takes it. Escape reaches the window, and a dialog
# around the field (the fake's "modal") takes it as Back and closes.
dev_case hide-keyboard-back
: > "$case_dir/adb/keyboard"; : > "$case_dir/adb/modal"
screen "$case_dir/adb/dump-1.xml" "$(node EditText query Item true)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_flow "$case_dir/flow.json"
begin "hideKeyboard on Android: Back while the keyboard is up, no escape, and a dialog around the field stays"
status_is 0; fake_used
has out.txt "hideKeyboard: keyboard closed"
has adb/log "shell input keyevent 4"; lacks adb/log "keyevent 111"
[ -e "$case_dir/adb/modal" ] || no "the dialog around the field closed"
verdict

# FOCUS_MAIN, FOCUS_DIALOG - the focused window as dumpsys names it.
FOCUS_MAIN='  mCurrentFocus=Window{1a2b u0 com.example/com.example.MainActivity}'
FOCUS_DIALOG='  mCurrentFocus=Window{3c4d u0 com.example}'

dev_case hide-keyboard-escape-fallback
: > "$case_dir/adb/keyboard"; : > "$case_dir/adb/back-stays"
printf '%s\n' "$FOCUS_MAIN" > "$case_dir/adb/focus"
screen "$case_dir/adb/dump-1.xml" "$(node EditText query Item true)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_flow "$case_dir/flow.json"
begin "hideKeyboard on Android: a keyboard Back leaves up gets escape, with a warning"
status_is 0
has out.txt "Back did not close the keyboard - trying escape, which a dialog around the field may take as Back and close"
has out.txt "keyboard closed (escape)"
[ "$(grep -n 'keyevent' "$case_dir/adb/log" | cut -d' ' -f4 | tr '\n' ' ')" = "4 111 " ] \
  || no "keys were not Back then escape: $(grep 'keyevent' "$case_dir/adb/log" | tr '\n' ' ')"
verdict

dev_case hide-keyboard-escape-dialog
: > "$case_dir/adb/keyboard"; : > "$case_dir/adb/back-stays"
printf '%s\n' "$FOCUS_MAIN" > "$case_dir/adb/focus"; printf '%s\n' "$FOCUS_DIALOG" > "$case_dir/adb/modal"
screen "$case_dir/adb/dump-1.xml" "$(node EditText query Item true)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_flow "$case_dir/flow.json"
begin "hideKeyboard on Android: escape that closes the dialog around the field with the keyboard fails the step"
status_is 1
has out.txt "escape closed the keyboard and the window with it - focus went from 'mCurrentFocus=Window{3c4d u0 com.example}' to 'mCurrentFocus=Window{1a2b u0 com.example/com.example.MainActivity}'"
verdict

# The keyboard went between the caller's question and the close: kb_close asks
# again itself, and presses nothing.
dev_case hide-keyboard-gone-before-key
: > "$case_dir/adb/keyboard"; : > "$case_dir/adb/modal"; printf 'up down' > "$case_dir/adb/kb-reads"
screen "$case_dir/adb/dump-1.xml" "$(node EditText query Item true)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_flow "$case_dir/flow.json"
begin "hideKeyboard on Android: a keyboard gone by the time of the key gets no key at all"
status_is 0
has out.txt "hideKeyboard: no keyboard was up any more"
lacks adb/log "keyevent"
[ -e "$case_dir/adb/modal" ] || no "the dialog around the field closed"
verdict

# A keyboard that takes a moment to go after Back is waited for, not sent escape.
dev_case hide-keyboard-slow
: > "$case_dir/adb/keyboard"; : > "$case_dir/adb/modal"; printf 'up up up up' > "$case_dir/adb/kb-reads"
screen "$case_dir/adb/dump-1.xml" "$(node EditText query Item true)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_flow "$case_dir/flow.json"
begin "hideKeyboard on Android: a keyboard still going 0.5 s after Back is waited for, and gets no escape"
status_is 0
has out.txt "hideKeyboard: keyboard closed"
has adb/log "shell input keyevent 4"; lacks adb/log "keyevent 111"
[ -e "$case_dir/adb/modal" ] || no "the dialog around the field closed"
verdict

dev_case hide-keyboard-android-none
screen "$case_dir/adb/dump-1.xml" "$(node EditText query Item)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_flow "$case_dir/flow.json"
begin "hideKeyboard on Android: with no keyboard up no key is pressed, Back least of all"
status_is 0; fake_used
has out.txt "no keyboard was up"
lacks adb/log "keyevent"
verdict

# The close before a swipe is the same close.
dev_case hide-keyboard-before-swipe
: > "$case_dir/adb/keyboard"; : > "$case_dir/adb/modal"
screen "$case_dir/adb/dump-1.xml" "$(node EditText query Item true)" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_flow "$case_dir/flow.json"
begin "scroll on Android: the keyboard is closed with Back before the swipe, and a dialog around the field stays"
status_is 0
has out.txt "before swiping: keyboard closed"
has adb/log "shell input keyevent 4"; lacks adb/log "keyevent 111"; has adb/log "input swipe"
[ -e "$case_dir/adb/modal" ] || no "the dialog around the field closed"
verdict

# hideKeyboard on iOS. A simulator lists its keyboard as plain buttons, one per
# key, and no element of type keyboard; escape does not close it.
ios_case ios-hide-keyboard-drag
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/drag-closes"
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"a@b.c"')"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: keys listed as buttons are a keyboard, and a drag above it closes it"
status_is 0
has out.txt "keyboard closed (drag)"
has idb/log "ui swipe"
lacks idb/log "ui key"; lacks idb/log "ui tap"
verdict

# idone <y> - a "Done" button 60 wide and 40 high at x 320: on the bar above
# the keys when its bottom edge is within 80 points above their top row.
idone(){ printf '{"type":"Button","role_description":"button","AXLabel":"Done","frame":{"x":320,"y":%s,"width":60,"height":40}}' "$1"; }

# The drag does not close this keyboard (#91); the bar above it has Done.
ios_case ios-hide-keyboard-done
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"; : > "$case_dir/idb/return-closes"
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"a@b.c"')" "$(idone 546)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a keyboard the drag leaves up is closed with Done on the bar above it"
status_is 0
has out.txt "keyboard closed (Done above the keyboard - the app's own button, it may have acted)"
has idb/log "ui swipe"; has idb/log "ui tap --udid FAKE-UDID 350 566"; lacks idb/log "ui key"
verdict

# No room for the drag is no reason to stop: Done is still there.
ios_case ios-hide-keyboard-no-room-done
printf '150' > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" "$(itext email 40 '"a@b.c"')" "$(idone 80)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a keyboard with no room above it for the drag goes on to Done"
status_is 0
has out.txt "keyboard closed (Done above the keyboard - the app's own button, it may have acted)"
lacks idb/log "ui swipe"; has idb/log "ui tap --udid FAKE-UDID 350 100"; lacks idb/log "ui key"
verdict

# A "Done" at the top of the screen is the app's own button, not the bar above
# the keys, and is not tapped.
ios_case ios-hide-keyboard-done-elsewhere
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" "$(idone 60)" "$(itext email 200 '"a@b.c"')"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a Done that is not on the bar above the keys is not tapped"
status_is 1
has out.txt "the keyboard is still up after a drag above it - not tried: Done (no Done button above the keyboard) - if this form may take Return, close it with pressKey 'enter'"
lacks idb/log "ui tap"; lacks idb/log "ui key"
verdict

# A modal form: Cancel and Done in its navigation bar, a "+" high up. The "+"
# is not a key, so the keyboard top stays at its keys, and the bar's Done -
# which would save the form - is not tapped.
ios_case ios-hide-keyboard-nav-done
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" \
  '{"type":"Button","role_description":"button","AXLabel":"Cancel","frame":{"x":16,"y":50,"width":70,"height":44}}' \
  "$(idone 50)" \
  '{"type":"Button","role_description":"button","AXLabel":"+","frame":{"x":180,"y":110,"width":40,"height":40}}' \
  "$(itext title 200 '"Item"')"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a one-character button high up is not a key, and a Done in the navigation bar is not tapped"
status_is 1
has out.txt "the keyboard is still up after a drag above it - not tried: Done (no Done button above the keyboard)"
has idb/log "ui swipe"; lacks idb/log "ui tap"
verdict

# A full-width Done riding on the keyboard is the form's own button.
ios_case ios-hide-keyboard-footer-done
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" "$(itext title 200 '"Item"')" \
  '{"type":"Button","role_description":"button","AXLabel":"Done","frame":{"x":16,"y":530,"width":358,"height":50}}'
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a full-width Done above the keyboard is not the keyboard bar, and is not tapped"
status_is 1
has out.txt "not tried: Done (no Done button above the keyboard)"
lacks idb/log "ui tap"
verdict

# The return key itself may be labelled Done; pressing it is Return.
ios_case ios-hide-keyboard-return-done
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"; printf 'Done' > "$case_dir/idb/return-label"
tree "$case_dir/idb/desc-1.json" "$(itext title 200 '"Item"')"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a return key labelled Done is not the bar's Done, and is not tapped"
status_is 1
has out.txt "not tried: Done (no Done button above the keyboard)"
lacks idb/log "ui tap"; lacks idb/log "ui key"
verdict

# itoolbar <x> <width> - a toolbar on top of the keys (y 546-590).
itoolbar(){ printf '{"type":"Toolbar","role_description":"toolbar","AXLabel":"","frame":{"x":%s,"y":546,"width":%s,"height":44}}' "$1" "$2"; }

ios_case ios-hide-keyboard-toolbar-done
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" "$(itext title 200 '"Item"')" "$(itoolbar 0 402)" "$(idone 548)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a Done inside the toolbar on top of the keys is tapped"
status_is 0
has out.txt "keyboard closed (Done above the keyboard - the app's own button, it may have acted)"
has idb/log "ui tap --udid FAKE-UDID 350 568"
verdict

# A keyboard element whose frame takes in the bar: the top is still the keys'.
ios_case ios-hide-keyboard-element-bar
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/keyboard-element"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" "$(itext title 200 '"Item"')" "$(itoolbar 0 402)" "$(idone 548)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a keyboard element that takes in the bar keeps the Done above the keys reachable"
status_is 0
has out.txt "keyboard closed (Done above the keyboard"
has idb/log "ui swipe"; has idb/log "ui tap --udid FAKE-UDID 350 568"
verdict

ios_case ios-hide-keyboard-toolbar-outside
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" "$(itext title 200 '"Item"')" "$(itoolbar 0 300)" "$(idone 548)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: with a toolbar on top of the keys, a Done outside it is not tapped"
status_is 1
has out.txt "not tried: Done (no Done button above the keyboard)"
lacks idb/log "ui tap"
verdict

ios_case ios-hide-keyboard-nothing
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/return-closes"
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"a@b.c"')" "$(idone 546)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a keyboard neither closes stops the step with what was tried, and Return is not pressed"
status_is 1
has out.txt "hideKeyboard: the keyboard is still up after a drag above it, the Done button above it - if this form may take Return, close it with pressKey 'enter'"
lacks out.txt "not tried"; lacks idb/log "ui key"
verdict

# Return would close this keyboard, and could submit the form with it.
ios_case ios-hide-keyboard-no-return
: > "$case_dir/idb/keyboard"; : > "$case_dir/idb/return-closes"
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"a@b.c"')"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a keyboard the drag leaves up stops the flow, and Return is never pressed for it"
status_is 1
has out.txt "the keyboard is still up after a drag above it"
has out.txt "close it with pressKey 'enter'"
has idb/log "ui swipe"; lacks idb/log "ui key"
verdict

ios_case ios-hide-keyboard-no-room
printf '150' > "$case_dir/idb/keyboard"; : > "$case_dir/idb/drag-closes"
tree "$case_dir/idb/desc-1.json" "$(itext email 100 '"a@b.c"')"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a keyboard with no room above it for the drag says that, not that a drag failed"
status_is 1
has out.txt "the keyboard reaches up to y 150, with no room above it"
lacks out.txt "a drag did not"; lacks out.txt "after a drag"
lacks idb/log "ui swipe"; lacks idb/log "ui key"
verdict

KAPP='{"type":"Application","role_description":"application","AXLabel":"App","frame":{"x":0,"y":0,"width":402,"height":874}}'
# A numeric keypad labels its key "Delete" with a capital D (#145): it is a
# keyboard when the ten digits around it have the shape of a keypad.
ios_case ios-hide-keypad
: > "$case_dir/idb/keypad"; : > "$case_dir/idb/drag-closes"
tree "$case_dir/idb/desc-1.json" "$KAPP" "$(itext amount 200 '"12"')"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a numeric keypad with its capital Delete is a keyboard, and the drag closes it"
status_is 0; has out.txt "keyboard closed (drag)"; has idb/log "ui swipe"; lacks out.txt "no keyboard was up"
verdict

# idb also lists elements parked below the window: the bottom of the screen is
# the window's, not the lowest frame in the tree.
ios_case ios-hide-keypad-parked
: > "$case_dir/idb/keypad"; : > "$case_dir/idb/drag-closes"
tree "$case_dir/idb/desc-1.json" "$KAPP" "$(itext amount 200 '"12"')" \
  '{"type":"Button","role_description":"button","AXLabel":"Later","frame":{"x":0,"y":2000,"width":100,"height":40}}'
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: an element parked below the window does not hide the keypad"
status_is 0; has out.txt "keyboard closed (drag)"; lacks out.txt "no keyboard was up"
verdict

# A one-character button of the app above the form does not move the drag:
# it is measured from the keypad's keys, whose top is at y 583.
ios_case ios-hide-keypad-app-letter
: > "$case_dir/idb/keypad"; : > "$case_dir/idb/drag-closes"
tree "$case_dir/idb/desc-1.json" "$KAPP" "$(itext amount 200 '"12"')" \
  '{"type":"Button","role_description":"button","AXLabel":"A","frame":{"x":10,"y":150,"width":30,"height":40}}'
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: the drag over a keypad starts above its keys, not above an app's letter button"
status_is 0; has out.txt "keyboard closed (drag)"; has idb/log "200 433 200 523"
verdict

# The drag leaves this keypad up; the bar above its keys has Done.
ios_case ios-hide-keypad-done
: > "$case_dir/idb/keypad"; : > "$case_dir/idb/done-closes"
tree "$case_dir/idb/desc-1.json" "$KAPP" "$(itext amount 200 '"12"')" "$(idone 539)"
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: a keypad the drag leaves up is closed with Done on the bar above it"
status_is 0
has out.txt "keyboard closed (Done above the keyboard - the app's own button, it may have acted)"
has idb/log "ui swipe"; has idb/log "ui tap --udid FAKE-UDID 350 559"; lacks idb/log "ui key"
verdict

# The same buttons drawn by an app in the top half of its screen: a "Delete"
# and ten digits of its own are not a keypad.
ios_case ios-hide-keypad-app-digits
tree "$case_dir/idb/desc-1.json" "$KAPP" \
  $(for d in 1 2 3 4 5 6 7 8 9 0; do printf '{"type":"Button","role_description":"button","AXLabel":"%s","frame":{"x":%d,"y":100,"width":30,"height":40}} ' "$d" $(( d * 36 )); done) \
  '{"type":"Button","role_description":"button","AXLabel":"Delete","frame":{"x":40,"y":300,"width":120,"height":40}}'
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: an app's Delete and digit buttons high on the screen are not a keypad"
status_is 0; has out.txt "no keyboard was up"; lacks idb/log "ui swipe"
verdict

ios_case ios-hide-keyboard-none
tree "$case_dir/idb/desc-1.json" "$(itext email 200 '"a@b.c"')" \
  '{"type":"Button","role_description":"button","AXLabel":"Delete","frame":{"x":40,"y":300,"width":120,"height":40}}' \
  '{"type":"Button","role_description":"button","AXLabel":"A","frame":{"x":40,"y":360,"width":40,"height":40}}' \
  '{"type":"Button","role_description":"button","AXLabel":"B","frame":{"x":90,"y":360,"width":40,"height":40}}'
flow_file "$case_dir/flow.json" '{ "do": "hideKeyboard" }'
run_ios "$case_dir/flow.json"
begin "hideKeyboard on iOS: an app's own Delete and letter buttons are not a keyboard"
status_is 0
has out.txt "no keyboard was up"
lacks idb/log "ui swipe"; lacks idb/log "ui key"
verdict

# ── a tap asks what is really under its point (idb describe-point) ───────────
# ibutton <id> - a button 200 wide and 100 high at 100,300: its centre is 200,350.
ibutton(){ printf '{"type":"Button","role_description":"button","AXUniqueId":"%s","AXLabel":"Go","frame":{"x":100,"y":300,"width":200,"height":100}}' "$1"; }
# ipoint <id or empty> <x> <y> <w> <h> - what describe-point answers.
ipoint(){ printf '{"type":"Other","AXUniqueId":%s,"AXLabel":"","frame":{"x":%s,"y":%s,"width":%s,"height":%s}}' \
  "$([ -n "$1" ] && printf '"%s"' "$1" || printf 'null')" "$2" "$3" "$4" "$5" > "$case_dir/idb/point.json"; }
taps_are(){ local got; got="$(grep -c '^ui tap ' "$case_dir/idb/log" 2>/dev/null)"
  [ "$got" = "$1" ] || no "$got taps, wanted $1"; }

ios_case ios-tap-self
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
ipoint go 100 300 200 100
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "go" }'
run_ios "$case_dir/flow.json"
begin "tapId on iOS: the point answers the target itself, and the tap goes"
status_is 0; taps_are 1; lacks out.txt "covered"
verdict

ios_case ios-tap-covered
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
ipoint tab-progress 0 330 402 60
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "go" }'
run_ios "$case_dir/flow.json"
begin "tapId on iOS: an element drawn over the target fails the step by name, nothing tapped"
status_is 1; taps_are 0; has out.txt "'go' at 200,350 is covered by tab-progress"
verdict

ios_case ios-tap-part
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
ipoint "" 150 330 100 40
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "go" }'
run_ios "$case_dir/flow.json"
begin "tapId on iOS: an element with no id inside the target's frame is a part of it, and the tap goes"
status_is 0; taps_are 1; lacks out.txt "covered"
verdict

ios_case ios-tap-other-id-inside
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
ipoint date-day 180 320 40 64
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "go" }'
run_ios "$case_dir/flow.json"
begin "tapId on iOS: an element with an id of its own inside the target's frame is another control, not a part"
status_is 1; taps_are 0; has out.txt "'go' at 200,350 is covered by date-day"
verdict

ios_case ios-tap-unknown
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "go" }'
run_ios "$case_dir/flow.json"
begin "tapId on iOS: no answer from describe-point taps as before, with a warning"
status_is 0; taps_are 1; has out.txt "could not read what is under 'go' at 200,350"
verdict

# ── a miss by id says what it saw (#64) ──────────────────────────────────────
# idnode <id> <x1> <y1> <x2> <y2> - an Android node with these corners. A
# keyboard collapses the nodes under it: bottom above top.
idnode(){ printf '<node index="0" text="" resource-id="com.example:id/%s" class="android.widget.EditText" package="com.example" content-desc="" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" password="false" selected="false" bounds="[%d,%d][%d,%d]" />' "$1" "$2" "$3" "$4" "$5"; }
IDROOT='<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example" content-desc="" bounds="[0,0][1080,2400]" />'

dev_case id-miss-zero
screen "$case_dir/adb/dump-1.xml" "$IDROOT" "$(idnode password-input 116 974 564 954)"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "password-input" }'
run_flow "$case_dir/flow.json"
begin "tapId: an id on a node with no area says so, with the frame, nothing tapped"
status_is 1; fake_used; lacks adb/log "input tap"
has out.txt "no element with id 'password-input' on the screen - it is in the tree at zero size [116,974][564,954] (pixels), which is what a keyboard over it looks like"
verdict

dev_case id-miss-off
screen "$case_dir/adb/dump-1.xml" "$IDROOT" "$(idnode footer 0 2500 1080 2600)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "footer" }'
run_flow "$case_dir/flow.json"
begin "assertId: an id on a node outside the screen says so, with the frame"
status_is 1; has out.txt "assert FAILED: no element with id 'footer' on the screen - it is in the tree outside the screen at [0,2500][1080,2600] (pixels)"
verdict

dev_case id-miss-none
screen "$case_dir/adb/dump-1.xml" "$IDROOT" "$(idnode email 100 500 900 600)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "password-input" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: an id nowhere in the tree keeps the old words, with nothing added"
status_is 1; has out.txt "no element with id 'password-input'"; lacks out.txt "in the tree at"
verdict

dev_case id-miss-zero-clear
screen "$case_dir/adb/dump-1.xml" "$IDROOT" "$(idnode password-input 116 974 564 954)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "password-input" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: the same words for a node with no area"
status_is 1; has out.txt "it is in the tree at zero size [116,974][564,954] (pixels)"
verdict

dev_case id-miss-zero-box
screen "$case_dir/adb/dump-1.xml" "$IDROOT" "$(idnode password-input 116 974 564 954)" "$(idnode email 100 500 900 600)"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "password-input", "box": { "minHeight": 10 } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId: the same words for a node with no area"
status_is 1; has out.txt "assert FAILED: no element with id 'password-input' on the screen - it is in the tree at zero size [116,974][564,954] (pixels)"
verdict

dev_case id-miss-zero-box-other
screen "$case_dir/adb/dump-1.xml" "$IDROOT" "$(idnode password-input 116 974 564 954)" "$(idnode email 100 500 900 600)"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "email", "box": { "above": "password-input" } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId: an id compared with, on a node with no area, says so"
status_is 1; has out.txt "assert FAILED: no element with id 'password-input' on the screen to compare id 'email' with - it is in the tree at zero size [116,974][564,954] (pixels), which is what a keyboard over it looks like"
verdict

ios_case ios-id-miss-zero
tree "$case_dir/idb/desc-1.json" '{"type":"Application","role_description":"application","AXLabel":"App","frame":{"x":0,"y":0,"width":402,"height":874}}' \
  '{"type":"Button","role_description":"button","AXUniqueId":"go","AXLabel":"Go","frame":{"x":100,"y":300,"width":0,"height":40}}'
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "go" }'
run_ios "$case_dir/flow.json"
begin "tapId on iOS: a node with no area is named in points, with no keyboard promised"
status_is 1; has out.txt "no element with id 'go' on the screen - it is in the tree at zero size [100,300][100,340] (points)"
lacks out.txt "keyboard over it"; taps_are 0
verdict

ios_case ios-taptext-other-id-inside
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
ipoint date-day 180 320 40 64
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Go" }'
run_ios "$case_dir/flow.json"
begin "tapText on iOS: an element with an id of its own inside the target's frame is another control, as for tapId"
status_is 1; taps_are 0; has out.txt "'Go' at 200,350 is covered by date-day"
verdict

ios_case ios-tap-part-overhang
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
ipoint "" 99 330 120 40
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "go" }'
run_ios "$case_dir/flow.json"
begin "tapId on iOS: an id-less part whose frame sticks out of the target by a point is still a part - its centre is inside"
status_is 0; taps_are 1; lacks out.txt "covered"
verdict

ios_case ios-optional-covered
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
ipoint tab-progress 0 330 402 60
flow_file "$case_dir/flow.json" '{ "do": "optionalTapText", "value": "Go" }'
run_ios "$case_dir/flow.json"
begin "optionalTapText on iOS: a covered target is left alone with a warning, and the flow goes on"
status_is 0; taps_are 0; has out.txt "optional 'Go' is covered by tab-progress - not tapped"
verdict

ios_case ios-optional-unknown
tree "$case_dir/idb/desc-1.json" "$(ibutton go)"
flow_file "$case_dir/flow.json" '{ "do": "optionalTapText", "value": "Go" }'
run_ios "$case_dir/flow.json"
begin "optionalTapText on iOS: no answer from describe-point taps as before, with a warning"
status_is 0; taps_are 1; has out.txt "could not read what is under optional 'Go' at 200,350"
verdict

# A "Skip" (a dismiss label) of 80x40 at 286,813 - centre 326,833 - under a tab button.
iskip(){ printf '{"type":"Button","role_description":"button","AXUniqueId":"card-skip","AXLabel":"Skip","frame":{"x":286,"y":813,"width":80,"height":40}}'; }

ios_case ios-dismiss-covered
tree "$case_dir/idb/desc-1.json" "$(iskip)"
ipoint tab-progress 321 785 81 55
flow_file "$case_dir/flow.json" '{ "do": "dismiss" }'
run_ios "$case_dir/flow.json"
begin "dismiss on iOS: a dismiss label under a tab button is not a pop-up - left alone, with a warning"
status_is 0; taps_are 0; has out.txt "dismiss: 'Skip' is covered by tab-progress - not a pop-up, left alone"
verdict

ios_case ios-dismiss-unknown
tree "$case_dir/idb/desc-1.json" "$(iskip)"
flow_file "$case_dir/flow.json" '{ "do": "dismiss" }'
run_ios "$case_dir/flow.json"
begin "dismiss on iOS: no answer from describe-point taps as before, with a warning"
status_is 0; has out.txt "dismiss: could not read what is under 'Skip' at 326,833"
verdict

# ── the resident screen helper (#105) ────────────────────────────────────────
# The helper is tests/fake-sdk/uia2-server, one per case on a free port, and
# the fake adb forwards to it. The cache starts with the pinned pair already
# marked as installed on the fake device, so a case downloads and installs
# nothing unless it means to - the fake APKs could never match the real sha.
SERVER_SHA="$(sed -n 's/^UIA2_SERVER_SHA="\(.*\)"$/\1/p' "$YUKTI")"
TEST_SHA="$(sed -n 's/^UIA2_TEST_SHA="\(.*\)"$/\1/p' "$YUKTI")"
SERVER_APK="$(sed -n 's/^UIA2_VER="\(.*\)"$/appium-uiautomator2-server-\1.apk/p' "$YUKTI")"
CACHE_SUB="$(sed -n 's/^UIA2_VER="\(.*\)"$/yukti\/uia2-\1/p' "$YUKTI")"
CACHE="cache/$CACHE_SUB"
server_pid=""
helper_case(){ dev_case "$1"; mkdir -p "$case_dir/$CACHE" "$case_dir/bin"
  printf '%s %s' "$SERVER_SHA" "$TEST_SHA" > "$case_dir/$CACHE/installed-emulator-5554"
  : > "$case_dir/adb/installed"
  /usr/bin/python3 "$ROOT/tests/fake-sdk/uia2-server" "$case_dir/adb" & server_pid=$!
  local i; for i in $(seq 1 50); do [ -s "$case_dir/adb/server-port" ] && break; sleep 0.1; done; }
# Remove one file of the case. The guard keeps an empty case_dir from turning
# the path into one at the root.
gone(){ rm -f "${case_dir:?}/$1"; }
# Stop what a case left running: the fake server, and a fake `am instrument`
# that waits for the helper to be stopped.
helper_done(){ gone adb/running; [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; server_pid=""; }
# helper_screen <file> <element>... - the tree as the helper writes it:
# indented, one element per line, each named by its class.
helper_screen(){ local f="$1" n; shift
  { printf "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\r\n"
    printf '<hierarchy index="0" class="hierarchy" rotation="0" width="1080" height="2400">\r\n'
    printf '  <android.widget.FrameLayout index="0" package="com.example" class="android.widget.FrameLayout" text="" resource-id="" bounds="[0,0][1080,2400]" displayed="true">\r\n'
    for n in "$@"; do printf '    %s\r\n' "$n"; done
    printf '  </android.widget.FrameLayout>\r\n</hierarchy>'; } > "$f"; }
# hnode <class> <resource-id> <text> - one element as the helper writes it: no
# content-desc when it is empty, attributes of its own the dump does not have.
hnode(){ printf '<android.widget.%s index="0" package="com.example" class="android.widget.%s" text="%s" resource-id="com.example:id/%s" clickable="true" enabled="true" focusable="true" focused="false" password="false" bounds="[0,%d][1080,%d]" displayed="true" />' \
  "$1" "$1" "$3" "$2" "$(node_y "$2")" "$(( $(node_y "$2") + 120 ))"; }
# run_helper <yukti args...> [-- VAR=value...] - like run_flow, with the helper
# allowed and the case's own cache and PATH.
run_helper(){ local a=() e=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do a+=("$1"); shift; done
  [ $# -gt 0 ] && { shift; e=("$@"); }
  env -u ANDROID_SDK_ROOT -u YUKTI_HELPER -u YUKTI_HELPER_KEEP -u ANDROID_SERIAL \
    ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android PATH="$case_dir/bin:$PATH" \
    FAKE_ADB_DIR="$case_dir/adb" YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" \
    XDG_CACHE_HOME="$case_dir/cache" ${e[@]+"${e[@]}"} "$YUKTI" "${a[@]}" > "$case_dir/out" 2>&1
  run_status=$?
  sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"; }
count_is(){ local n; n="$(grep -cF -- "$2" "$case_dir/$1" 2>/dev/null)"; [ "${n:-0}" -eq "$3" ] || no "$1 has \"$2\" ${n:-0} times, wanted $3"; }
is_there(){ [ -e "$case_dir/$1" ] || no "$1 is missing"; }
value_is(){ [ "$(cat "$case_dir/$1" 2>/dev/null)" = "$2" ] || no "$1 is '$(cat "$case_dir/$1" 2>/dev/null)', wanted '$2'"; }

# State by id (#103): selected and checked, as the dump carries them.
# sroot <node>... - the nodes inside a full-screen root, so the root is the screen.
sroot(){ printf '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2400]">'
  local n; for n in "$@"; do printf '%s' "$n"; done; printf '</node>'; }
# snode <id> <y> <selected> [checkable] [checked] - a control 1080 wide, 100 high.
snode(){ printf '<node index="0" text="%s" resource-id="com.example:id/%s" class="android.view.ViewGroup" package="com.example" content-desc="" checkable="%s" checked="%s" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="%s" bounds="[0,%d][1080,%d]" />' \
  "$1" "$1" "${4:-false}" "${5:-false}" "$3" "$2" "$(( $2 + 100 ))"; }

dev_case state-selected
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode day 300 false)" "$(snode week 500 true)")"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "week", "selected": true }' '{ "do": "assertId", "value": "day", "selected": false }'
run_flow "$case_dir/flow.json"
begin "assertId selected: Week is selected and Day is not"
status_is 0; fake_used; has out.txt "assert id: 'week' on screen at 540 550, selected"; has out.txt "'day' on screen at 540 350, not selected"
verdict

dev_case state-not-selected
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode day 300 true)" "$(snode week 500 false)")"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "week", "selected": true }'
run_flow "$case_dir/flow.json"
begin "assertId selected: the same flow is red while Week is not selected"
status_is 1; has out.txt "assert FAILED: 'week' is not selected"
verdict

dev_case state-checked
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode remind 300 false true true)" "$(snode plain 500 false)")"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "remind", "checked": true }' '{ "do": "assertId", "value": "remind", "checked": false }'
run_flow "$case_dir/flow.json"
begin "assertId checked: a checked switch passes checked true and fails checked false"
status_is 1; has out.txt "'remind' on screen at 540 350, checked"; has out.txt "assert FAILED: 'remind' is checked"
verdict

dev_case state-not-checkable
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode plain 500 false)")"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "plain", "checked": false }'
run_flow "$case_dir/flow.json"
begin "assertId checked: an element that is not checkable fails by name, never passes checked false"
status_is 1; has out.txt "'plain' has no checked state"
verdict

dev_case state-wait
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode week 500 false)")"
screen "$case_dir/adb/dump-2.xml" "$(sroot "$(snode week 500 true)")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "week", "selected": true, "timeout": 5 }'
run_flow "$case_dir/flow.json"
begin "waitForId selected: the wait goes on until the element is in the state"
status_is 0; reads_are 2; has out.txt "waitFor id: 'week' on screen at 540 550 after"; has out.txt "s, selected"
verdict

dev_case state-wait-timeout
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode week 500 false)")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "week", "selected": true, "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId selected: on the screen in the other state is a failure that says so"
status_is 1; has out.txt "waitFor id FAILED: 'week' is not selected after 1s"
verdict

dev_case state-wait-optional
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode week 500 false)")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "week", "selected": true, "timeout": 1, "optional": true }'
run_flow "$case_dir/flow.json"
begin "waitForId selected optional: the miss is skipped with its words"
status_is 0; has out.txt "'week' is not selected after 1s - optional, the flow goes on"
verdict

helper_case helper-reads
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "tapId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a live helper answers every read, no dump at all"
status_is 0; fake_used; file_absent adb/dumps
has adb/settings '"waitForIdleTimeout":500'; count_is adb/http-log "/source" 2
lacks adb/log "am instrument"; lacks adb/log "force-stop"
has out.txt "· read helper"; has out.txt "screen reads: 2 by the helper, 0 by uiautomator dump, 0 fallback(s)"
verdict; helper_done

# With no HOME and no XDG_CACHE_HOME (#58) the cache is this user's own
# directory in TMPDIR; one made by somebody else - here a link - is not used.
helper_case helper-no-home
NH_CACHE="tmp/yukti-$(id -u)/${CACHE_SUB#yukti/}"
mkdir -p -m 700 "$case_dir/tmp/yukti-$(id -u)"; mkdir -p "$case_dir/$NH_CACHE"
cp "$case_dir/$CACHE/installed-emulator-5554" "$case_dir/$NH_CACHE/"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- HOME= XDG_CACHE_HOME=
begin "helper: no HOME - the cache in the user's own directory in TMPDIR is used"
status_is 0; fake_used; has adb/log "am instrument"; has out.txt "screen reads: 1 by the helper, 0 by uiautomator dump"
verdict; helper_done

helper_case helper-no-home-foreign
mkdir -p "$case_dir/elsewhere"; mkdir -p "$case_dir/tmp"; ln -s "$case_dir/elsewhere" "$case_dir/tmp/yukti-$(id -u)"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- HOME= XDG_CACHE_HOME=
begin "helper: no HOME - a cache directory that is not the user's own is not used, the read falls back to the dump"
status_is 0; has out.txt "it has no cache directory"; lacks adb/log "am instrument"
[ -z "$(ls -A "$case_dir/elsewhere")" ] || no "something was written into the linked directory"
verdict; helper_done

helper_case helper-start-fails
: > "$case_dir/adb/start-fails"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a start that fails is tried once, then the run dumps"
status_is 0; count_is adb/log "am instrument" 1; count_is adb/log "force-stop" 1; value_is adb/dumps 2
count_is out.txt "screen helper: it did not come up" 1
value_is "$CACHE/start-fail-emulator-5554" 1
verdict; helper_done

helper_case helper-nonxml
: > "$case_dir/adb/running"; echo nonxml > "$case_dir/adb/source-mode"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: three answers in a row that are not a tree stop it, and the run dumps"
status_is 0; value_is adb/sources 3; count_is adb/log "force-stop" 1; value_is adb/dumps 2
has out.txt "three reads in a row gave no tree"; has out.txt "1 fallback(s)"
verdict; helper_done

helper_case helper-nonxml-once
: > "$case_dir/adb/running"; echo nonxml-once > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: one answer that is not a tree is read again, not given up on"
status_is 0; value_is adb/sources 2; file_absent adb/dumps; lacks adb/log "force-stop"
verdict; helper_done

helper_case helper-off
gone "$CACHE/installed-emulator-5554"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER=0
begin "helper: YUKTI_HELPER=0 never asks the helper and never touches the cache"
status_is 0; value_is adb/dumps 1; file_absent adb/http-log
[ -z "$(ls -A "$case_dir/$CACHE")" ] || no "the cache was written: $(ls -A "$case_dir/$CACHE")"
lacks adb/log "forward"; lacks adb/log "get-serialno"; lacks adb/log "pidof"
verdict; helper_done

helper_case helper-sha-mismatch
gone adb/installed; gone "$CACHE/installed-emulator-5554"
printf 'not the release' > "$case_dir/adb/download-$SERVER_APK"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a download that does not match the pinned sha is thrown away, nothing installed"
status_is 0; has adb/log "curl https://github.com/appium/appium-uiautomator2-server/releases/download/"
lacks adb/log "install -r -g"; lacks adb/log "am instrument"
file_absent "$CACHE/$SERVER_APK"; [ -z "$(ls -A "$case_dir/$CACHE" | grep download)" ] || no "a partial download was left in the cache"
count_is out.txt "did not match the pinned sha256" 1; value_is adb/dumps 2
file_absent "$CACHE/start-fail-emulator-5554"
verdict; helper_done

helper_case helper-no-forward
gone adb/server-port
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a flow that gets no forward from adb says so, and counts it as a fallback"
status_is 0; has adb/log "forward tcp:0 tcp:6790"; lacks adb/log "am instrument"; value_is adb/dumps 2
count_is out.txt "screen helper: adb could not forward a port to it" 1
has out.txt "screen reads: 0 by the helper, 2 by uiautomator dump, 1 fallback(s)"
verdict; helper_done

helper_case helper-stale-session
: > "$case_dir/adb/running"; printf 'stale' > "$case_dir/$CACHE/session-emulator-5554"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "helper: a kept session that expired is opened again, and the wait set after it"
status_is 0; file_absent adb/dumps; value_is adb/sessions 1; has adb/settings '"waitForIdleTimeout":500'
has adb/http-log "GET /session/stale/source"; value_is "$CACHE/session-emulator-5554" s1
verdict; helper_done

helper_case helper-forward-lost
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
gone adb/forward; : > "$case_dir/adb/log"
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "helper: a forward lost with adbd is made again; nothing is installed or started"
status_is 0; file_absent adb/dumps; has adb/log "forward tcp:0 tcp:6790"
lacks adb/log "install"; lacks adb/log "am instrument"; value_is adb/sessions 1
verdict; helper_done

helper_case helper-stop
: > "$case_dir/adb/running"; echo 4321 > "$case_dir/adb/forward"
printf 's9' > "$case_dir/$CACHE/session-emulator-5554"; echo 2 > "$case_dir/$CACHE/start-fail-emulator-5554"
run_helper helper stop
begin "helper: 'yukti helper stop' stops it, removes the forward and forgets the kept state"
status_is 0; has adb/log "force-stop"; has adb/log "forward --remove tcp:4321"
file_absent adb/running; file_absent adb/forward
file_absent "$CACHE/session-emulator-5554"; file_absent "$CACHE/start-fail-emulator-5554"
verdict; helper_done

helper_case helper-start-twice
: > "$case_dir/adb/start-fails"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"; run_helper flow "$case_dir/flow.json"; run_helper flow "$case_dir/flow.json"
begin "helper: after two failed starts in a row the device is not tried again"
status_is 0; count_is adb/log "am instrument" 2; value_is "$CACHE/start-fail-emulator-5554" 2
has out.txt "failed to start twice in a row"
verdict; helper_done

helper_case helper-holds-dump
: > "$case_dir/adb/foreign"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER=0
begin "helper: a dump killed by somebody's helper says so"
status_is 1; has out.txt "is running on the device and takes every dump down"; has out.txt "yukti helper stop"
verdict; helper_done

helper_case helper-no-dump
printf 'garbage' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER=0
begin "helper: with no helper on the device an empty dump keeps its old message"
status_is 1; has out.txt "the screen may still be animating"; lacks out.txt "takes every dump down"
verdict; helper_done

helper_case helper-other-sha
printf 'old old' > "$case_dir/$CACHE/installed-emulator-5554"
printf 'tampered' > "$case_dir/$CACHE/$SERVER_APK"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: another pair on the device means a reinstall, and the cached APK is checked first"
status_is 0; lacks adb/log "install -r -g"; file_absent "$CACHE/$SERVER_APK"
has adb/log "curl "; has out.txt "did not match the pinned sha256"
verdict; helper_done

helper_case helper-tags
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" \
  '<android.widget.FrameLayout index="0" package="com.example" class="android.widget.FrameLayout" text="" resource-id="" bounds="[0,100][1080,2400]">' \
  '<com.facebook.react.views.view.ReactViewGroup index="0" package="com.example" class="com.facebook.react.views.view.ReactViewGroup" text="" resource-id="" bounds="[0,100][1080,2400]">' \
  '<com.example.Outer$Inner index="0" package="com.example" class="com.example.Outer$Inner" text="" resource-id="" bounds="[0,100][1080,2400]">' \
  "$(hnode TextView deep "$MARK")" '</com.example.Outer$Inner>' '</com.facebook.react.views.view.ReactViewGroup>' '</android.widget.FrameLayout>'
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "deep" }' '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_helper flow "$case_dir/flow.json"
begin "helper: every tag but the root becomes <node>, open, closing and empty"
status_is 1; has out.txt "not on screen"; file_full res/flow-fail.xml; has res/flow-fail.xml "$MARK"
lacks res/flow-fail.xml "<android."; lacks res/flow-fail.xml "</android."; lacks res/flow-fail.xml "<com."; lacks res/flow-fail.xml "</com."
has res/flow-fail.xml "<hierarchy"; has res/flow-fail.xml "</hierarchy>"
verdict; helper_done

helper_case helper-ui-kept
: > "$case_dir/adb/running"; printf 's1' > "$case_dir/adb/session"; printf '1' > "$case_dir/adb/sessions"
printf 's1' > "$case_dir/$CACHE/session-emulator-5554"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
run_helper ui
begin "helper: 'yukti ui' reads through a kept helper whose forward was lost, and leaves it up"
status_is 0; has out "com.example:id/title"; file_absent adb/dumps; has adb/log "forward tcp:0 tcp:6790"
is_there adb/running; lacks adb/log "force-stop"; lacks adb/log "am instrument"
verdict; helper_done

helper_case helper-ui-forward-kept
: > "$case_dir/adb/running"; printf 's1' > "$case_dir/adb/session"; printf '1' > "$case_dir/adb/sessions"
printf 's1' > "$case_dir/$CACHE/session-emulator-5554"; cp "$case_dir/adb/server-port" "$case_dir/adb/forward"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
run_helper ui
begin "helper: 'yukti ui' reads through a kept helper and its forward, checked once"
status_is 0; has out "com.example:id/title"; file_absent adb/dumps
lacks adb/log "forward tcp:0"; count_is adb/http-log "/status" 1; is_there adb/running
verdict; helper_done

helper_case helper-ui-none
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
run_helper ui
begin "helper: 'yukti ui' with no helper dumps, and starts nothing"
status_is 0; has out "com.example:id/title"; value_is adb/dumps 1
lacks adb/log "am instrument"; lacks adb/log "forward tcp:0"; lacks out.txt "screen helper:"
verdict; helper_done

helper_case helper-own-stop
printf '#!/bin/sh\necho "setsid $*" >> "%s/adb/log"; exit 1\n' "$case_dir" > "$case_dir/bin/setsid"; chmod +x "$case_dir/bin/setsid"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a flow starts it without setsid(1) and stops it on the way out"
status_is 0; file_absent adb/dumps; count_is adb/log "am instrument" 1; lacks adb/log "setsid"
has adb/log "force-stop"; file_absent adb/running; file_absent adb/forward
file_absent "$CACHE/start-fail-emulator-5554"
verdict; helper_done

helper_case helper-keep
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "helper: YUKTI_HELPER_KEEP=1 leaves it up with its session for the next run"
status_is 0; count_is adb/log "am instrument" 1; lacks adb/log "force-stop"
is_there adb/running; value_is "$CACHE/session-emulator-5554" s1
verdict; run_helper helper stop; helper_done

helper_case helper-slow
: > "$case_dir/adb/running"; echo slow > "$case_dir/adb/source-mode"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_TIMEOUT=1
begin "helper: a read that times out is a failed try; three of them and the run dumps"
status_is 0; value_is adb/sources 3; value_is adb/dumps 1; has out.txt "three reads in a row gave no tree"
[ "$(sed -n '/source/,$p' "$case_dir/adb/http-log" | grep -c /status)" -eq 0 ] || no "/status was asked after a timeout"
verdict; helper_done

helper_case helper-died
: > "$case_dir/adb/running"; echo die > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a helper that died mid-run is started again, once"
status_is 0; file_absent adb/dumps; count_is adb/log "am instrument" 1; value_is adb/sessions 2
verdict; helper_done

# ── searching a list: the helper's gesture and the time limit (#107) ──────────
# A list from y 200 to 2200 on the fake 1080x2400 screen, rows 200 apart with
# their centres at 300, 500 ... 2100. The anchors the search picks there:
#   a screen at a time (80%): the row at 1900, 85% of the way, to 300
#   two fifths (40%):         the row at 1500, 65% of the way, to 700
# hlist / dlist <prefix> [target-label target-centre] - one such list as the
# helper writes it / as a dump does, its rows named "<prefix> 1".."<prefix> 10";
# a target replaces the row whose centre it takes.
# A prefix @n is a window on one long list instead: rows "R n".."R n+9", so two
# windows share the rows a swipe leaves on the screen, as a real list does. The
# screen-long swipe moves it by 8 rows, two fifths by 4 (#117).
lrows(){ local fmt="$1" p="$2" t="${3:-}" ty="${4:-0}" k y lab
  for k in 1 2 3 4 5 6 7 8 9 10; do y=$(( 100 + k * 200 )); lab="$p $k"
    case "$p" in @*) lab="R $(( ${p#@} + k - 1 ))";; esac
    [ "$y" = "$ty" ] && lab="$t"
    printf "$fmt" "$lab" $(( y - 50 )) $(( y + 50 )); done; }
hlist(){ printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true">'
  lrows '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,%d]" displayed="true" />' "$@"
  printf '</android.widget.ScrollView>'; }
dlist(){ printf '<node index="0" text="" resource-id="com.example:id/list" class="android.widget.ScrollView" package="com.example" content-desc="" scrollable="true" bounds="[0,200][1080,2200]">'
  lrows '<node index="0" text="%s" resource-id="" class="android.widget.TextView" package="com.example" content-desc="" scrollable="false" bounds="[40,%d][1040,%d]" />' "$@"
  printf '</node>'; }
# The gestures the helper was sent, one JSON line each.
gestures_are(){ local n; n="$(wc -l < "$case_dir/adb/actions" 2>/dev/null || echo 0)"
  [ "${n// /}" -eq "$1" ] || no "the helper was sent ${n// /} gestures, wanted $1"; }
# gesture_line <n> <x1> <y1> <x2> <y2> - the n-th gesture went from one point to
# the other, stopped, and lifted at speed zero: a 20 ms move to the same point.
gesture_line(){ "$PY3" - "$case_dir/adb/actions" "$@" <<'PY' || no "gesture $1 is not $2,$3 -> $4,$5 with a stop before the lift"
import json, sys
f, n, x1, y1, x2, y2 = sys.argv[1], int(sys.argv[2]), *map(int, sys.argv[3:7])
g = json.loads(open(f).read().splitlines()[n - 1])["actions"][0]
a = g["actions"]
assert g["parameters"]["pointerType"] == "touch"
assert [s["type"] for s in a] == ["pointerMove", "pointerDown", "pointerMove", "pause", "pointerMove", "pointerUp"]
assert (a[0]["x"], a[0]["y"], a[0]["duration"]) == (x1, y1, 0)
assert (a[2]["x"], a[2]["y"]) == (x2, y2) and a[3]["duration"] >= 150
assert (a[4]["x"], a[4]["y"]) == (x2, y2) and a[4]["duration"] >= 20
PY
}
PY3=/usr/bin/python3

helper_case scroll-helper-far
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: with the helper a search swipes a screen at a time, with a finger that stops before it lifts"
status_is 0; file_absent adb/dumps; gestures_are 2; count_is adb/http-log "/actions" 2
gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 300
lacks adb/log "input swipe"; count_is out.txt "· swipe helper" 2; has out.txt "· search 2 swipes"
count_is out.txt " ms 540,1900 -> 540,300" 2
lacks out.txt "went past the gesture"
verdict; helper_done

helper_case scroll-helper-up
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @1 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "direction": "up" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: going up, the screen-long swipe runs the other way"
status_is 0; gestures_are 1; gesture_line 1 540 500 540 2100
verdict; helper_done

helper_case scroll-helper-clear
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1 Target 1900)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @5 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "edges": "clear" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: an element in view is brought into the band by two fifths, not flown past it"
status_is 0; gestures_are 1; gesture_line 1 540 1500 540 700
verdict; helper_done

helper_case scroll-helper-taptext
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: tapText searches with the same gesture and taps through adb"
status_is 0; gestures_are 1; lacks adb/log "input swipe"; has adb/log "input tap 540 1100"
verdict; helper_done

helper_case scroll-helper-step
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: the scroll step keeps its own swipe through adb"
status_is 0; gestures_are 0; has adb/log "input swipe"
verdict; helper_done

# Known, and measured on a device rather than here: a read that catches the list
# before its rows are drawn sees no rows, and the search swipes on. On a device
# the rows it skipped may have held the element; here the next screen holds it.
helper_case scroll-helper-undrawn
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true" />'
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a list read before its rows are drawn is swiped past (known, see the comment)"
status_is 0; gestures_are 2; value_is adb/sources 3; count_is out.txt "· full tree" 1; lacks out.txt "went past the gesture"
verdict; helper_done

# A row of tiles 200 wide from x 8, centres at 108, 324 ... 972; the
# screen-long swipe starts on the last tile, 90% of the way, and goes 80%. A
# prefix @n is a window on one long row, tiles "T n".."T n+4"; the screen-long
# swipe moves it by 4 tiles.
htiles(){ local p="$1" t="${2:-}" k x lab
  printf '<android.widget.HorizontalScrollView index="0" package="com.example" class="android.widget.HorizontalScrollView" text="" resource-id="com.example:id/row" scrollable="true" bounds="[0,800][1080,1100]" displayed="true">'
  for k in 1 2 3 4 5; do x=$(( 8 + (k - 1) * 216 )); lab="$p $k"
    case "$p" in @*) lab="T $(( ${p#@} + k - 1 ))";; esac
    [ "$k" = 3 ] && [ -n "$t" ] && lab="$t"
    printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[%d,900][%d,1000]" displayed="true" />' "$lab" "$x" $(( x + 200 )); done
  printf '</android.widget.HorizontalScrollView>'; }
helper_case scroll-helper-right
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(htiles @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(htiles @5 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "direction": "right" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: sideways, the screen-long swipe runs along the row at its height"
status_is 0; gestures_are 1; gesture_line 1 942 950 78 950
verdict; helper_done

# ── the strips at the sides of the screen (#123) ──────────────────────────────
# On the fake 420 dpi screen a swipe starts 137 px or further from either side:
# 50 dp, where a stack screen takes the touch as the back gesture, and 2 more.
# The tile the screen-long swipe takes above is centred at 972, in the right
# strip, so the swipe starts at 942 on the same tile and keeps its length.
# elist @n <x1> <x2> [target] - the window of hlist on one long list, with the
# row the screen-long swipe takes (the 9th, centre 1900) drawn from x1 to x2
# only; a target takes the row centred at 1100.
elist(){ local n="${1#@}" a="$2" b="$3" t="${4:-}" k y lab l r
  printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true">'
  for k in 1 2 3 4 5 6 7 8 9 10; do y=$(( 100 + k * 200 )); lab="R $(( n + k - 1 ))"; l=40; r=1040
    [ "$k" = 9 ] && { l="$a"; r="$b"; }
    [ -n "$t" ] && [ "$y" = 1100 ] && lab="$t"
    printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[%d,%d][%d,%d]" displayed="true" />' "$lab" "$l" $(( y - 50 )) "$r" $(( y + 50 )); done
  printf '</android.widget.ScrollView>'; }

helper_case scroll-helper-edge-anchor
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(elist @1 20 200)"
helper_screen "$case_dir/adb/helper-2.xml" "$(elist @9 20 200)"
helper_screen "$case_dir/adb/helper-3.xml" "$(elist @17 20 200 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a line of text that reaches into the left strip is swiped from its part outside it; asking the density does not take the tree"
status_is 0; gestures_are 2; gesture_line 1 137 1900 137 300; gesture_line 2 137 1900 137 300
count_is adb/log "shell wm density" 1; lacks out.txt "density unavailable"
verdict; helper_done

helper_case scroll-helper-edge-skip
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(elist @1 10 120)"
helper_screen "$case_dir/adb/helper-2.xml" "$(elist @8 10 120 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a line of text all in the left strip is passed over for another one"
status_is 0; gestures_are 1; gesture_line 1 540 1700 540 300
verdict; helper_done

helper_case scroll-helper-edge-left
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(htiles @5)"
helper_screen "$case_dir/adb/helper-2.xml" "$(htiles @1 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "direction": "left" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: sideways to the left, the swipe does not start in the left strip and run as the back gesture"
status_is 0; gestures_are 1; gesture_line 1 137 950 1001 950
verdict; helper_done

helper_case scroll-helper-edge-no-density
: > "$case_dir/adb/running"; : > "$case_dir/adb/no-density"
helper_screen "$case_dir/adb/helper-1.xml" "$(elist @1 20 200)"
helper_screen "$case_dir/adb/helper-2.xml" "$(elist @9 20 200)"
helper_screen "$case_dir/adb/helper-3.xml" "$(elist @17 20 200 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: without the density the strip is a seventh of the width, and the run says so once"
status_is 0; gestures_are 2; gesture_line 1 156 1900 156 300; gesture_line 2 156 1900 156 300
count_is out.txt "screen density unavailable, keeping swipes 156 px off the sides of the screen" 1
verdict; helper_done

dev_case scroll-dump
screen "$case_dir/adb/dump-1.xml" "$(dlist A)"
screen "$case_dir/adb/dump-2.xml" "$(dlist B)"
screen "$case_dir/adb/dump-3.xml" "$(dlist C Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_flow "$case_dir/flow.json"
begin "scroll: without the helper a search swipes two fifths through adb, as before"
status_is 0; count_is adb/log "input swipe 540 1500 540 700 600" 2; count_is out.txt "· swipe adb" 2
lacks out.txt "went past the gesture"
verdict

helper_case scroll-helper-gone
: > "$case_dir/adb/running"; echo gone > "$case_dir/adb/actions-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
screen "$case_dir/adb/dump-1.xml" "$(dlist B)"
screen "$case_dir/adb/dump-2.xml" "$(dlist C Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a helper gone during a gesture is given up on, that line goes through adb at half the length, the rest of the step too"
status_is 0; gestures_are 1; has out.txt "it did not answer a swipe"
has adb/log "input swipe 540 1900 540 1100 600"; has adb/log "input swipe 540 1500 540 700 600"
has out.txt "· swipe adb"; has out.txt "(helper: rc 2)"
verdict; helper_done

# Two refusals leave the list where it was, so the second read looks like the
# end of the list: the search waits there for it to grow, and the control swipe
# of that wait - on adb by then - is what moves it.
helper_case scroll-helper-refuses
: > "$case_dir/adb/running"; echo fail > "$case_dir/adb/actions-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist B Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a refused gesture is not repeated on adb, and after two refusals the run swipes through adb"
status_is 0; gestures_are 2; count_is out.txt "(helper: rc 5)" 2; count_is adb/log "input swipe" 1
has out.txt "· search 1 swipes"
file_absent adb/dumps
verdict; helper_done

helper_case scroll-helper-hang
: > "$case_dir/adb/running"; echo hang > "$case_dir/adb/actions-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
screen "$case_dir/adb/dump-1.xml" "$(dlist A)"
screen "$case_dir/adb/dump-2.xml" "$(dlist B Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_TIMEOUT=1
begin "scroll: a gesture with no answer in time is not swiped again, and the helper is given up on"
status_is 0; gestures_are 1; has out.txt "(helper: rc 4)"; has out.txt "it did not answer a swipe"
count_is adb/log "input swipe" 1
verdict; helper_done

helper_case scroll-budget
: > "$case_dir/adb/running"
for k in $(seq 1 80); do helper_screen "$case_dir/adb/helper-$k.xml" "$(hlist "@$(( 8 * k - 7 ))")"; done
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_SCROLL_BUDGET=2
begin "scroll: a list that keeps moving stops the search after its time, not after a count"
status_is 1; has out.txt "still moving after 2s of swiping down, 'Target' not found"
grep -q "· search [1-9][0-9]* swipes" "$case_dir/out.txt" || no "no search line with swipes"
verdict; helper_done

# ── a list that travels further than the finger (#117) ───────────────────────
# The screen-long swipe from window @1 leaves rows 9 and 10 on the screen - the
# seam. A read without them, with rows of its own, is a list that went past the
# gesture: the search goes back by two fifths until the seam is there again,
# and on from it by two fifths.
helper_case scroll-over-back
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a list that went past the gesture is swiped back to the seam, then on by two fifths"
status_is 0; gestures_are 3; count_is out.txt "went past the gesture - going back" 1
gesture_line 1 540 1900 540 300; gesture_line 2 540 700 540 1500; gesture_line 3 540 1500 540 700
verdict; helper_done

helper_case scroll-over-found-back
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @21 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: an element met on the way back is the answer"
status_is 0; gestures_are 2; gesture_line 2 540 700 540 1500
verdict; helper_done

# The way back checks the seam that was lost, not the seam of its own swipe: the
# read after the first swipe back has neither rows 9-10 nor the element, and the
# search goes back once more.
helper_case scroll-over-back-twice
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @21)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-5.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: the way back goes on until the lost seam is on the screen again"
status_is 0; gestures_are 4
gesture_line 2 540 700 540 1500; gesture_line 3 540 700 540 1500; gesture_line 4 540 1500 540 700
verdict; helper_done

# Rows with no label give no seam, and nothing is judged.
hblank(){ printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true">'
  lrows '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="" hint="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,%d]" displayed="true" />' X
  printf '</android.widget.ScrollView>'; }
helper_case scroll-over-no-seam
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hblank)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a swipe over rows with no label leaves no seam to check"
status_is 0; gestures_are 2; lacks out.txt "went past the gesture"
verdict; helper_done

# Back to the start of the list without the seam: forward again at once, with
# no wait for the start to grow: two swipes back, the control swipe at the start,
# and the fifth gesture is the forward one. The miss at the end is the usual one.
helper_case scroll-over-start
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @41)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @65)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @101)"
helper_screen "$case_dir/adb/helper-6.xml" "$(hlist @201)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "timeout": 1 }'
run_helper flow "$case_dir/flow.json"
begin "scroll: the way back that reaches the start turns forward at once"
status_is 1; has out.txt "reached the end of the list going down and it did not grow for 1s, 'Target' is not in it"
count_is out.txt "went past the gesture" 1
gesture_line 2 540 700 540 1500; gesture_line 3 540 700 540 1500; gesture_line 5 540 1500 540 700
verdict; helper_done

# One way back per step: a list that goes past again after it is said so, and
# the search goes on.
helper_case scroll-over-twice
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @41)"
helper_screen "$case_dir/adb/helper-5.xml" "$(hlist @45 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a second overshoot in a step is said, not gone back for"
status_is 0; gestures_are 4; count_is out.txt "went past the gesture - going back" 1; count_is out.txt "went past the gesture" 2
gesture_line 4 540 1500 540 700
verdict; helper_done

# ── a row below the fold, and a swipe by the distance to it (#116) ──────────
# With allowInvisibleElements on, the helper keeps the rows below the fold, upside
# down: the top where the row stands in the content, the bottom pinned to the
# bottom of the list (2200). On the lists above the visible part is 200-2200 and
# the band 164-2306, so the top of the element is aimed at 1200, and the
# screen-long line, 1900 to 300, is the longest a distance swipe goes.
# below <label:top> - one such row; inlist <list> <element>... - the list with
# more elements inside it; hfull <list> <label:top>... - with rows below the fold.
below(){ printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,2200]" displayed="false" />' "${1%:*}" "${1##*:}"; }
inlist(){ local l="$1"; shift; printf '%s' "${l%</android.widget.ScrollView>}" "$@" '</android.widget.ScrollView>'; }
hfull(){ local l="$1" b r=""; shift; for b in "$@"; do r="$r$(below "$b")"; done; inlist "$l" "$r"; }
# full_reads_are <n> - n full reads, each the setting on, one source, the
# setting off, with no other request in between: no plain read sees the rows
# below the fold.
full_reads_are(){ "$PY3" - "$case_dir/adb/http-log" "$1" <<'PY' || no "http-log does not hold $1 full read(s) of: setting on, one source, setting off"
import sys
lines, n, got, i = open(sys.argv[1]).read().splitlines(), int(sys.argv[2]), 0, 0
while i < len(lines):
    if '"allowInvisibleElements":true' in lines[i]:
        assert lines[i + 1].startswith("GET ") and lines[i + 1].endswith("/source")
        assert '"allowInvisibleElements":false' in lines[i + 2]
        got += 1; i += 3; continue
    assert "allowInvisibleElements" not in lines[i]
    i += 1
assert got == n
PY
}

helper_case scroll-dist
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element below the fold is swiped to by its distance, one swipe, and found by a plain read"
status_is 0; gestures_are 1; gesture_line 1 540 1900 540 650; full_reads_are 1
count_is out.txt "· full tree" 1; has out.txt "· search 1 swipes"; value_is adb/sources 2
lacks out.txt "went past the gesture"
verdict; helper_done

# The list went 0.8 of the first swipe: 3500 to 2220 on 1600. The second swipe
# is the distance left divided by it, 1020 / 0.8.
helper_case scroll-dist-ratio
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:3500)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @9)" Target:2220)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @15 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the share the element travelled on one swipe sets the length of the next"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 625
full_reads_are 2; lacks out.txt "distance scroll ratio"
verdict; helper_done

helper_case scroll-dist-over
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a list that went past a distance swipe is said so and swiped back, as after any (#117)"
status_is 0; gestures_are 3; count_is out.txt "went past the gesture - going back (distance)" 1
gesture_line 1 540 1900 540 650; gesture_line 2 540 700 540 1500; gesture_line 3 540 1500 540 700
count_is out.txt "· full tree" 1
verdict; helper_done

helper_case scroll-dist-still
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @3 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a distance swipe that moved nothing ends it, and the control swipe follows"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 650; gesture_line 2 540 1300 540 800
count_is out.txt "· full tree" 1
verdict; helper_done

# Content above the element grew between the reads: its top went down, 3500 to
# 3600, and that share is no list moving.
helper_case scroll-dist-grew
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:3500)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @9)" Target:3600)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a share outside 0.5-1.5 is said and taken as 1"
status_is 0; gestures_are 2; count_is out.txt "· distance scroll ratio -0.06 out of range - using 1" 1
gesture_line 2 540 1900 540 300
verdict; helper_done

# No row on the screen - a list read before its rows are drawn, a canvas: same_rows
# has nothing to tell the list still by, the top of the element has. The swipe
# starts on the grid, 88% of the way.
hempty(){ printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true"></android.widget.ScrollView>'; }
helper_case scroll-dist-unlabelled
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hempty)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hempty)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hempty)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hempty)" Target:2450)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: on a list with no row on the screen, a top that did not move ends it"
status_is 0; gestures_are 2; gesture_line 1 540 1960 540 710; gesture_line 2 540 1960 540 360
count_is out.txt "· full tree" 2
verdict; helper_done

# A short list, 200-640, and the band cleared of its edges, 592-1878: the top
# is aimed at 616, and an element whose top is at 650 is 34 px away - no swipe
# is that short. The usual line goes out: the row at 500, 63% of the way.
SHORT_LIST='<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,640]" displayed="true">'
srow(){ printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,%d]" displayed="%s" />' "$@"; }
helper_case scroll-dist-short
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$SHORT_LIST$(srow 'A 1' 250 350 true)$(srow 'A 2' 450 550 true)</android.widget.ScrollView>"
helper_screen "$case_dir/adb/helper-full-1.xml" "$SHORT_LIST$(srow 'A 1' 250 350 true)$(srow 'A 2' 450 550 true)$(srow Target 650 640 false)</android.widget.ScrollView>"
helper_screen "$case_dir/adb/helper-2.xml" "$SHORT_LIST$(srow 'A 3' 250 350 true)$(srow Target 590 640 true)</android.widget.ScrollView>"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "edges": "clear" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element nearer than a swipe can go gets the usual line"
status_is 0; gestures_are 1; gesture_line 1 540 500 540 223; count_is out.txt "· full tree" 1
verdict; helper_done

# A slider over the row the screen-long line starts on: the distance swipe
# starts on the next line of text, the row at 1700, as any line would.
SLIDER='<android.widget.SeekBar index="0" package="com.example" class="android.widget.SeekBar" text="" resource-id="com.example:id/slider" scrollable="false" bounds="[0,1850][1080,1950]" displayed="true" />'
helper_case scroll-dist-finger
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(inlist "$(hlist @1)" "$SLIDER")"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(inlist "$(hlist @1)" "$SLIDER")" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the finger goes down on text, not on a slider"
status_is 0; gestures_are 1; gesture_line 1 540 1700 540 450
verdict; helper_done

# Not in the full tree: the search swipes to the lowest row below the fold by
# its distance, then goes on as it always did.
helper_case scroll-dist-end-grows
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" 'R 11:2250' 'R 15:3050')"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: not in the full tree - to the lowest row below the fold, then the usual search finds rows drawn later"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 300
count_is out.txt "· full tree" 2; lacks out.txt "lost the target"
verdict; helper_done

helper_case scroll-dist-end
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" 'R 11:2250' 'R 15:3050')"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hlist @9)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "timeout": 1 }'
run_helper flow "$case_dir/flow.json"
begin "distance: not in the full tree and the list ends - the usual miss, after the usual wait"
status_is 1; has out.txt "reached the end of the list going down and it did not grow for 1s, 'Target' is not in it"
count_is out.txt "· full tree" 2
verdict; helper_done

# The lowest row below the fold is another one after the swipe - a list that
# draws rows past its edge as it goes: 2900, then 2700 of another row. A share
# taken across two rows would be 0.12 and said; it is not taken.
helper_case scroll-dist-end-moves
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" 'R 11:2250' 'R 15:2900')"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @9)" 'R 19:2300' 'R 22:2700')"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @16)"
helper_screen "$case_dir/adb/helper-full-3.xml" "$(hlist @16)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @24 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: to the end, each swipe goes by the lowest row of its own read, no share between two rows"
status_is 0; gestures_are 3; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 400
gesture_line 3 540 1900 540 300; lacks out.txt "distance scroll ratio"; count_is out.txt "· full tree" 3
verdict; helper_done

# Lost (#122): after a distance swipe the element is neither on the screen nor
# below the fold - the swipe carried it above. The search goes back with the
# usual short swipe, not on down past it.
helper_case scroll-dist-lost
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @7)" 'R 17:2300')"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @3 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element neither on the screen nor below the fold any more is said lost, and the search goes back for it"
status_is 0; count_is out.txt "· distance scroll lost the target - going back" 1; gestures_are 2
gesture_line 1 540 1900 540 650; gesture_line 2 540 700 540 1500; count_is out.txt "· full tree" 2
verdict; helper_done

# The way back for a lost element reaches the start of the list without it:
# forward again at once, as the way back of #117 does, and the element is
# found below. Three swipes back, the control swipe at the start, two reads of
# the start that turn the search forward, and the sixth gesture is the forward
# one.
helper_case scroll-dist-lost-start
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @7)" 'R 17:2300')"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @3)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-5.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-6.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-7.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-8.xml" "$(hlist @5 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the way back for a lost element that reaches the start of the list turns forward and finds it below"
status_is 0; count_is out.txt "· distance scroll lost the target - going back" 1; gestures_are 6
count_is out.txt "· full tree" 2; lacks out.txt "went past the gesture"
gesture_line 2 540 700 540 1500; gesture_line 3 540 700 540 1500; gesture_line 4 540 700 540 1500
gesture_line 5 540 900 540 1400; gesture_line 6 540 1500 540 700
verdict; helper_done

# The way back for a lost element is not judged by the seam of #117: a read
# after a swipe back with none of the rows that were on the screen is not a list
# that ran past, and the search goes on back.
helper_case scroll-dist-lost-no-past
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @7)" 'R 17:2300')"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @21 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the way back for a lost element is not taken for a list that ran past"
status_is 0; count_is out.txt "· distance scroll lost the target - going back" 1; lacks out.txt "went past the gesture"
gestures_are 3; gesture_line 2 540 700 540 1500; gesture_line 3 540 700 540 1500
verdict; helper_done

# A lazy list holds no row below the fold: the full read changes nothing.
helper_case scroll-dist-lazy
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: no rows below the fold - one full read, then the search as before"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 300
full_reads_are 1; lacks out.txt "distance"
verdict; helper_done

helper_case scroll-dist-nonxml
: > "$case_dir/adb/running"; echo nonxml-full > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a full read that is not a tree switches the setting off, and the search goes on as before"
status_is 0; has out.txt "· full tree not read (helper: rc 5)"; full_reads_are 1
gestures_are 1; gesture_line 1 540 1900 540 300; value_is adb/sessions 1; file_absent adb/dumps
verdict; helper_done

helper_case scroll-dist-died
: > "$case_dir/adb/running"; echo die-full > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a helper that died on the full read is started again, once, and the swipe is its"
status_is 0; has out.txt "· full tree not read (helper: rc 2)"; count_is adb/log "am instrument" 1
value_is adb/sessions 2; gestures_are 1; lacks adb/log "input swipe"; file_absent adb/dumps
verdict; helper_done

# The setting not taken back: the session is forgotten in the run and in the
# cache - with either left, the next read would go on it, the setting still on
# - and a new one opened, with the wait and without the setting.
helper_case scroll-dist-stuck
: > "$case_dir/adb/running"; echo fail-false > "$case_dir/adb/settings-mode"
printf 's1' > "$case_dir/adb/session"; printf '1' > "$case_dir/adb/sessions"; printf 's1' > "$case_dir/$CACHE/session-emulator-5554"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "distance: a session that did not take the setting back is dropped, here and in the cache, and opened anew"
status_is 0; value_is adb/sessions 2; value_is "$CACHE/session-emulator-5554" s2
has adb/settings '"waitForIdleTimeout":500'; lacks adb/settings "allowInvisibleElements"
gestures_are 1; gesture_line 1 540 1900 540 650; lacks adb/log "input swipe"
has adb/http-log "GET /session/s2/source"
verdict; helper_done

# In the full tree on the screen, in the plain read not there: nothing to swipe
# to by distance, and the line says so - not the same as no rows below the fold.
helper_case scroll-dist-on-full
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hlist @1 Target 1100)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element on the screen in the full tree only is said, and the search goes on as before"
status_is 0; count_is out.txt "· distance scroll: the full tree has the element on the screen" 1
gestures_are 1; gesture_line 1 540 1900 540 300
verdict; helper_done

helper_case scroll-dist-two
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:3000 Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: of two equal matches below the fold, the nearer one"
status_is 0; gestures_are 1; gesture_line 1 540 1900 540 650
verdict; helper_done

helper_case scroll-dist-shown
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1 Target 1100)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1 Target 1100)" Target:2450)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element on the screen needs no full read, whatever lies below"
status_is 0; gestures_are 0; full_reads_are 0; lacks out.txt "full tree"
verdict; helper_done

helper_case scroll-dist-budget
: > "$case_dir/adb/running"
for k in $(seq 1 80); do
  helper_screen "$case_dir/adb/helper-$k.xml" "$(hlist "@$(( 8 * k - 7 ))")"
  helper_screen "$case_dir/adb/helper-full-$k.xml" "$(hfull "$(hlist "@$(( 8 * k - 7 ))")" "Z $k:3900")"
done
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_SCROLL_BUDGET=2
begin "distance: swipes by distance are within the time of the search, and its miss is the usual one"
status_is 1; has out.txt "still moving after 2s of swiping down, 'Target' not found"
[ "$(grep -c '· full tree' "$case_dir/out.txt")" -ge 2 ] || no "fewer than two full reads"
verdict; helper_done

# The keyboard is closed first, and the screen read again: the full read comes
# after that read, not before it.
helper_case scroll-dist-keyboard
: > "$case_dir/adb/running"; : > "$case_dir/adb/keyboard"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the full read comes after the keyboard is closed"
status_is 0; has out.txt "keyboard closed"; gestures_are 1; full_reads_are 1
[ "$(awk '/allowInvisibleElements":true/ {print n; exit} /source$/ {n++}' "$case_dir/adb/http-log")" = 2 ] \
  || no "the full read did not come after the second plain read"
verdict; helper_done

dev_case scroll-blind
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_flow "$case_dir/flow.json"
begin "scroll: a screen with no list still gets eight swipes down the middle"
status_is 1; has out.txt "searched 8 swipes down"; count_is adb/log "input swipe" 8; has out.txt "· search 8 swipes"
verdict

ios_case scroll-ios
tree "$case_dir/idb/desc-1.json" '{"type":"ScrollView","role_description":"scroll view","AXLabel":"","frame":{"x":0,"y":100,"width":402,"height":700}}' \
  '{"type":"StaticText","role_description":"text","AXLabel":"Row 1","frame":{"x":20,"y":200,"width":300,"height":40}}' \
  '{"type":"StaticText","role_description":"text","AXLabel":"Row 2","frame":{"x":20,"y":600,"width":300,"height":40}}'
tree "$case_dir/idb/desc-2.json" '{"type":"ScrollView","role_description":"scroll view","AXLabel":"","frame":{"x":0,"y":100,"width":402,"height":700}}' \
  '{"type":"StaticText","role_description":"text","AXLabel":"Target","frame":{"x":20,"y":400,"width":300,"height":40}}'
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_ios "$case_dir/flow.json"
begin "scroll: on iOS a search keeps the idb swipe of two fifths"
status_is 0; count_is idb/log "ui swipe" 1; has out.txt "· swipe idb"; lacks out.txt "went past the gesture"
count_is idb/log "--duration " 1
verdict

# iOS swipes move the finger at IOS_SWIPE_PT_S points a second (default 150):
# left to idb they often did not scroll, faster ones fling (see the engine). The
# fake idb has no screen size, so the 402x874 basis is used: a scroll down goes
# 201,611 -> 201,262, 349 points, 2.33 s.
ios_case scroll-ios-speed
tree "$case_dir/idb/desc-1.json" "$(itext name 100)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_ios "$case_dir/flow.json"
begin "scroll: on iOS a 349-point swipe takes 2.33 s at the default 150 points a second"
status_is 0; has idb/log "ui swipe --udid FAKE-UDID --duration 2.33 201 611 201 262"
verdict

ios_case scroll-ios-speed-env
tree "$case_dir/idb/desc-1.json" "$(itext name 100)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "up" }'
run_ios "$case_dir/flow.json" YUKTI_IOS_SWIPE_PT_S=349
begin "scroll: on iOS YUKTI_IOS_SWIPE_PT_S sets the speed - 349 points at 349 a second is 1 s"
status_is 0; has idb/log "ui swipe --udid FAKE-UDID --duration 1.00 201 393 201 742"
verdict

# Up starts in the middle band, not at 30%: a sticky header is a fixed number of
# points tall, and on a short screen 30% lies on it (iPhone SE: no move).
ios_case scroll-ios-up-start
tree "$case_dir/idb/desc-1.json" "$(itext name 100)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "up" }'
run_ios "$case_dir/flow.json" YUKTI_DEVICE_PT_W=375 YUKTI_DEVICE_PT_H=667
begin "scroll: on iOS up puts the finger down at 45% of the height - 300 on a 667-point screen, not 200"
status_is 0; has idb/log "187 300 187 566"; lacks idb/log "187 200 187"
verdict

ios_case scroll-ios-speed-floor
tree "$case_dir/idb/desc-1.json" "$(itext name 100)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_ios "$case_dir/flow.json" YUKTI_IOS_SWIPE_PT_S=5000
begin "scroll: on iOS a swipe never takes less than 0.3 s"
status_is 0; has idb/log "--duration 0.30 201 611 201 262"
verdict

ios_case scroll-ios-speed-bad
tree "$case_dir/idb/desc-1.json" "$(itext name 100)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_ios "$case_dir/flow.json" YUKTI_IOS_SWIPE_PT_S=fast
begin "scroll: on iOS a speed that is not a number stops the step and says so, nothing swiped"
status_is 1; has out.txt "YUKTI_IOS_SWIPE_PT_S must be a whole number of points a second above 0, with no leading zero, is 'fast'"
lacks idb/log "ui swipe"
verdict

# "00" passed the digit check and divided by zero: the swipe went out with no
# duration and the step passed. "007" read as 7 points a second (49.86 s).
ios_case scroll-ios-speed-zeros
tree "$case_dir/idb/desc-1.json" "$(itext name 100)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_ios "$case_dir/flow.json" YUKTI_IOS_SWIPE_PT_S=00
begin "scroll: on iOS a speed of 00 stops the step and says so, nothing swiped"
status_is 1; has out.txt "is '00'"; lacks idb/log "ui swipe"
verdict

ios_case scroll-ios-speed-leading-zero
tree "$case_dir/idb/desc-1.json" "$(itext name 100)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_ios "$case_dir/flow.json" YUKTI_IOS_SWIPE_PT_S=007
begin "scroll: on iOS a speed with a leading zero (007) stops the step and says so, nothing swiped"
status_is 1; has out.txt "is '007'"; lacks idb/log "ui swipe"
verdict

# ── an element at zero size, and a wait that may end without it (#111, #112) ─
# The root node comes first: the engine takes the first bounds of a dump as the
# screen. The button is the case these were made for - in the tree, at a point.
ROOT_NODE='<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example" content-desc="" bounds="[0,0][1080,2400]" />'
ZERO_BTN='<node index="0" text="" resource-id="com.example:id/btn" class="android.view.ViewGroup" package="com.example" content-desc="Ask" clickable="true" bounds="[174,60][174,60]" />'
SIZED_BTN='<node index="0" text="" resource-id="com.example:id/btn" class="android.view.ViewGroup" package="com.example" content-desc="Ask" clickable="true" bounds="[100,40][250,90]" />'
BELOW_BTN='<node index="0" text="" resource-id="com.example:id/btn" class="android.view.ViewGroup" package="com.example" content-desc="Ask" clickable="true" bounds="[100,2500][250,2550]" />'
# A guarded step that leaves a trace when it runs: a wait of nothing, titled.
RAN='{ "do": "wait", "value": "0", "title": "guarded step", "when": { "zeroSizeId": "btn" } }'

dev_case zero-wait-names-zero
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a timeout on a zero-size element says so, with its corners"
status_is 1; fake_used
has out.txt "'btn' not on screen after 1s - at zero size [174,60][174,60]"
has res/flow.xml "at zero size [174,60][174,60]"; red_is failure StepFailed 1 0
verdict

dev_case zero-wait-names-missing
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a timeout on an id that is not in the tree says so"
status_is 1; fake_used; has out.txt "'btn' not on screen after 1s - not in the tree"
verdict

dev_case zero-wait-names-outside
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$BELOW_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a timeout on an element below the screen says so"
status_is 1; fake_used; has out.txt "'btn' not on screen after 1s - outside the screen at [100,2500][250,2550]"
verdict

dev_case zero-wait-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a screen that cannot be read is not called any of the three"
status_is 1; fake_used; red_is error DeviceError 0 1
lacks out.txt "not in the tree"; lacks out.txt "at zero size"
verdict

# The read that names the state can find the element after all. A dump slower
# than the timeout makes the poll a single one, so the second dump is that last
# read, whatever the clock does.
dev_case zero-wait-last-read-finds
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
screen "$case_dir/adb/dump-2.xml" "$ROOT_NODE" "$SIZED_BTN"
printf '1.2' > "$case_dir/adb/dump-delay"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: an element the last read finds after the timeout passes the step"
status_is 0; fake_used; reads_are 2; has out.txt "'btn' on screen at 175 65 after"
lacks out.txt "not on screen"
verdict

dev_case optional-goes-on
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }' \
  '{ "do": "wait", "value": "0", "title": "the step after" }'
run_flow "$case_dir/flow.json"
begin "optional: a wait that ends without its element is skipped, and the flow goes on"
status_is 0; fake_used
has out.txt "'btn' not on screen after 1s - at zero size [174,60][174,60] - optional, the flow goes on"
has out.txt 'step 2 '"'"'wait'"'"' "the step after"'
has res/flow.xml 'skipped="1"'
has res/flow.xml "optional wait ended, the flow went on: 'btn' not on screen after 1s - at zero size [174,60][174,60]"
lacks res/flow.xml "condition not met"; lacks res/flow.xml "<failure"
verdict

dev_case optional-found
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SIZED_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }'
run_flow "$case_dir/flow.json"
begin "optional: an element that is there is waited for as always"
status_is 0; fake_used; has out.txt "'btn' on screen at 175 65"
has res/flow.xml 'skipped="0"'
verdict

dev_case optional-false
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": false }'
run_flow "$case_dir/flow.json"
begin "optional: false is the ordinary wait, and fails"
status_is 1; fake_used; red_is failure StepFailed 1 0
verdict

dev_case optional-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }' \
  '{ "do": "wait", "value": "0", "title": "the step after" }'
run_flow "$case_dir/flow.json"
begin "optional: a screen that cannot be read still stops the flow"
status_is 1; fake_used; red_is error DeviceError 0 1; lacks out.txt "the step after"
verdict

dev_case zero-when-holds
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: an element in the tree at zero size holds"
status_is 0; fake_used; has out.txt '"guarded step"'; lacks out.txt "skipped"
verdict

dev_case zero-when-missing
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: an id that is not in the tree does not hold"
status_is 0; fake_used; has out.txt "skipped: zeroSizeId 'btn'"
has res/flow.xml "condition not met: zeroSizeId 'btn'"
verdict

dev_case zero-when-sized
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SIZED_BTN"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: an element of a real size does not hold"
status_is 0; fake_used; has out.txt "skipped: zeroSizeId 'btn'"
verdict

dev_case zero-when-namesake
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN" "$SIZED_BTN"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: a zero-size node with a namesake that can be tapped does not hold"
status_is 0; fake_used; has out.txt "skipped: zeroSizeId 'btn'"
verdict

dev_case zero-when-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: a screen that cannot be read stops the flow"
status_is 1; fake_used; has out.txt "when (zeroSizeId 'btn')"; has res/flow.xml 'name="00 flow"'
verdict

# ── one read for a run of skipped steps (#172) ──────────────────────────────
# A step that is skipped touches nothing, so the conditions in a run of them
# answer from one read; the first step that runs makes the next condition read
# again. SKIP is a guarded step that does not run on a screen without the button.
SKIP='{ "do": "wait", "value": "0", "when": { "visibleId": "btn" } }'
SKIPN='{ "do": "wait", "value": "0", "when": { "notVisibleId": "title" } }'
# Two terms, as the sign-in block guards its steps, and both are asked (the
# builder sorts them: notVisibleId holds, visibleId does not): still one read.
SKIP2='{ "do": "wait", "value": "0", "when": { "notVisibleId": "btn", "visibleId": "btn" } }'
dev_case when-run-one-read
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" "$SKIP2" "$SKIPN" "$SKIP" "$SKIPN" "$SKIP" "$SKIP2" "$SKIPN" "$SKIP" "$SKIPN" "$SKIP"
run_flow "$case_dir/flow.json"
begin "when: ten guarded steps in a row, all skipped, read the screen once"
status_is 0; fake_used; reads_are 1; count_is out.txt "skipped: " 10
verdict

dev_case when-step-reads-again
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$(node TextView title Today)"
screen "$case_dir/adb/dump-2.xml" "$ROOT_NODE" "$SIZED_BTN"
flow_file "$case_dir/flow.json" "$SKIP" '{ "do": "wait", "value": "0", "title": "the step between" }' \
  '{ "do": "wait", "value": "0", "title": "guarded step", "when": { "visibleId": "btn" } }'
run_flow "$case_dir/flow.json"
begin "when: a step that runs between two guarded steps makes the next condition read again"
status_is 0; fake_used; reads_are 2; has out.txt '"the step between"'; has out.txt '"guarded step"'
verdict

dev_case when-platform-no-read
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE"
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "0", "when": { "platform": "ios" } }' \
  '{ "do": "wait", "value": "0", "when": { "platform": "ios" } }'
run_flow "$case_dir/flow.json"
begin "when: a condition on the platform alone reads no screen"
status_is 0; reads_are 0; count_is out.txt "skipped: " 2
verdict

# iOS: the same states in an idb tree. The window comes first, as the engine
# takes it for the screen.
IAPP='{"type":"Application","role_description":"application","AXLabel":"App","frame":{"x":0,"y":0,"width":402,"height":874}}'
IZERO='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask","frame":{"x":174,"y":60,"width":0,"height":0}}'
ISIZED='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask","frame":{"x":100,"y":40,"width":150,"height":50}}'

ios_case ios-zero-wait
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IZERO"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: a timeout on a zero-size element says so, with its corners"
status_is 1; has out.txt "'btn' not on screen after 1s - at zero size [174,60][174,60]"
verdict

ios_case ios-zero-wait-missing
tree "$case_dir/idb/desc-1.json" "$IAPP"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: a timeout on an id that is not in the tree says so"
status_is 1; has out.txt "'btn' not on screen after 1s - not in the tree"
verdict

IOFF='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask","frame":{"x":100,"y":2000,"width":150,"height":50}}'
ios_case ios-zero-wait-outside
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IOFF"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: a timeout on an element below the screen says so"
status_is 1; has out.txt "'btn' not on screen after 1s - outside the screen at [100,2000][250,2050]"
verdict

# An element with no frame has no place: not in the tree, as a node without
# bounds is on Android - not zero size.
INOFRAME='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask"}'
ios_case ios-zero-wait-noframe
tree "$case_dir/idb/desc-1.json" "$IAPP" "$INOFRAME"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: an element with no frame is not in the tree"
status_is 1; has out.txt "'btn' not on screen after 1s - not in the tree"
verdict

ios_case ios-zero-when-noframe
tree "$case_dir/idb/desc-1.json" "$IAPP" "$INOFRAME"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an element with no frame does not hold"
status_is 0; has out.txt "skipped: zeroSizeId 'btn'"
verdict

ios_case ios-optional-goes-on
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IZERO"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }' \
  '{ "do": "wait", "value": "0", "title": "the step after" }'
run_ios "$case_dir/flow.json"
begin "optional on iOS: a wait that ends without its element is skipped, and the flow goes on"
status_is 0; has out.txt "at zero size [174,60][174,60] - optional, the flow goes on"
has out.txt '"the step after"'; has res/flow.xml "optional wait ended, the flow went on"
verdict

ios_case ios-zero-when-holds
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IZERO"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an element in the tree at zero size holds"
status_is 0; has out.txt '"guarded step"'; lacks out.txt "skipped"
verdict

ios_case ios-zero-when-missing
tree "$case_dir/idb/desc-1.json" "$IAPP"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an id that is not in the tree does not hold"
status_is 0; has out.txt "skipped: zeroSizeId 'btn'"
verdict

ios_case ios-zero-when-sized
tree "$case_dir/idb/desc-1.json" "$IAPP" "$ISIZED"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an element of a real size does not hold"
status_is 0; has out.txt "skipped: zeroSizeId 'btn'"
verdict

ios_case ios-zero-when-unreadable
printf 'not a tree' > "$case_dir/idb/desc-1.json"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: a screen that cannot be read stops the flow"
status_is 1; has out.txt "when (zeroSizeId 'btn')"
verdict

ios_case ios-when-run-one-read
tree "$case_dir/idb/desc-1.json" "$IAPP" '{"type":"StaticText","role_description":"text","AXUniqueId":"title","AXLabel":"Today","frame":{"x":20,"y":120,"width":200,"height":30}}'
flow_file "$case_dir/flow.json" "$SKIP2" "$SKIPN" "$SKIP" "$SKIPN" "$SKIP" "$SKIP2" "$SKIPN" "$SKIP" "$SKIPN" "$SKIP"
run_ios "$case_dir/flow.json"
begin "when on iOS: ten guarded steps in a row, all skipped, read the screen once"
status_is 0; ireads_are 1; count_is out.txt "skipped: " 10
verdict

ios_case ios-when-step-reads-again
tree "$case_dir/idb/desc-1.json" "$IAPP"
tree "$case_dir/idb/desc-2.json" "$IAPP" "$ISIZED"
flow_file "$case_dir/flow.json" "$SKIP" '{ "do": "wait", "value": "0", "title": "the step between" }' \
  '{ "do": "wait", "value": "0", "title": "guarded step", "when": { "visibleId": "btn" } }'
run_ios "$case_dir/flow.json"
begin "when on iOS: a step that runs between two guarded steps makes the next condition read again"
status_is 0; ireads_are 2; has out.txt '"the step between"'; has out.txt '"guarded step"'
verdict

# The builder: what a file says is checked before anything runs.
new_case optional-check
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 20, "optional": true }' \
  '{ "do": "tapId", "value": "bell", "when": { "zeroSizeId": "btn" } }'
expect "check: optional and zeroSizeId build" 0 " - 2 steps" check "$case_dir/flow.json"

new_case optional-not-bool
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "optional": "yes" }'
expect "check: optional that is not a boolean is refused" 1 \
  "step 1 'waitForId': \"optional\" is true or false, got \"yes\"" check "$case_dir/flow.json"

new_case optional-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "waitFor", "value": "Ask", "optional": true }'
expect "check: optional on a step that does not take it is refused" 1 \
  "step 1 'waitFor': step 'waitFor' does not take \"optional\" - only waitForId does" check "$case_dir/flow.json"

new_case optional-on-include
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json", "optional": true }'
flow_file "$case_dir/b1.json" '{ "do": "wait", "value": "0" }'
expect "check: optional on an include is refused" 1 \
  "'optional' is not a key an include takes" check "$case_dir/flow.json"

new_case zero-when-not-text
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "0", "when": { "zeroSizeId": { "id": "btn" } } }'
expect "check: a zeroSizeId that is not text is refused" 1 \
  "condition 'zeroSizeId' must be text or a number" check "$case_dir/flow.json"

# ── a crashed app, not a missing element (#63) ───────────────────────────────
# After a failed step the engine asks the device whether the app of this run
# ($YUKTI_VARIANT) is still running and in front, and keeps its crash log. The
# fake adb answers from app-pid, focus, device-offset and crash.
app_cfg(){ printf '{ "variants": { "app": { "platform": "%s", "%s": "com.example" } } }\n' \
  "${1:-android}" "${2:-package}" > "$case_dir/cfg.json"; }
app_case(){ dev_case "$1"; app_cfg; screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)" "$(node TextView marker "$MARK")"
  flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'; }
run_app(){ run_flow "$case_dir/flow.json" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json" "$@"; }
FRONT='  mCurrentFocus=Window{7f3a2c1 u0 com.example/com.example.MainActivity}'
CRASH='--------- beginning of crash
10-19 23:40:01.123  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main
10-19 23:40:01.123  4242  4242 E AndroidRuntime: java.lang.IllegalStateException: bad address user.synthetic@example.invalid'
asked(){ grep -qF -- "$1" "$case_dir/adb/log" || no "the device was never asked: $1"; }
not_asked(){ ! grep -qF -- "$1" "$case_dir/adb/log" 2>/dev/null || no "the device was asked: $1"; }

app_case app-front
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' "$FRONT" > "$case_dir/adb/focus"
run_app
begin "app: running and in front - the step's message as before, and a note"
status_is 1; fake_used; red_is failure StepFailed 1 0
has res/flow.xml "not on screen"; has res/flow.xml "app: com.example running, in front"
lacks res/flow.xml "is not running"; has res/flow.xml "crash log: none since the flow started"
verdict

app_case app-gone
printf '%s\n' "$CRASH" > "$case_dir/adb/crash"; echo 3600 > "$case_dir/adb/device-offset"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_EMAIL}" }' \
  '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
screen "$case_dir/adb/dump-1.xml" "$(node EditText email @TYPED@ true)" "$(node TextView marker "$MARK")"
t_before=$(date +%s); run_app TEST_EMAIL='user.synthetic@example.invalid'; t_after=$(date +%s)
begin "app: gone - said first, its own type, and the crash log kept masked"
status_is 1; fake_used; red_is failure AppGone 1 0
has res/flow.xml 'message="the app com.example is not running: it was gone when the step failed'
has res/flow.xml "not on screen"; has res/flow.xml "crash log: flow-crash.txt (3 lines)"
has res/flow.xml "flow-crash.txt</system-out>"; file_full res/flow-crash.txt
has res/flow-crash.txt "FATAL EXCEPTION"; has res/flow-crash.txt "[typed]"; lacks res/flow-crash.txt "user.synthetic"
since="$(grep -oE 'logcat -b crash -d -v threadtime -t [^ ]+' "$case_dir/adb/log" | awk '{print $NF}')"
printf '%s' "$since" | grep -qE '^[0-9]+\.[0-9]{3}$' || no "logcat -t got '$since', not a time with a fraction"
awk -v s="$since" -v a="$t_before" -v b="$t_after" 'BEGIN { exit !(s >= a + 3597 && s <= b + 3599) }' \
  || no "logcat -t $since is not the flow's start on the device clock ($t_before..$t_after + 3600)"
verdict

app_case app-behind
echo 4242 > "$case_dir/adb/app-pid"
printf '%s\n' '  mCurrentFocus=Window{1b2c3d4 u0 com.android.launcher3/com.android.launcher3.uioverride.QuickstepLauncher}' > "$case_dir/adb/focus"
run_app
begin "app: running but not in front - the window that is, without its hash"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml 'message="the app com.example is running but not in front: com.android.launcher3/com.android.launcher3.uioverride.QuickstepLauncher'
lacks res/flow.xml "1b2c3d4"; asked "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"
verdict

app_case app-focus-null
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' '  mCurrentFocus=null' > "$case_dir/adb/focus"
run_app
begin "app: no focused window is not read as another app in front"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app state not read: no focused window"; lacks res/flow.xml "not in front"
verdict

app_case app-focus-popup
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' '  mCurrentFocus=Window{9e8f7a6 u0 PopupWindow:3c1d2e5}' > "$case_dir/adb/focus"
run_app
begin "app: a focused popup has no package and says so"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app state not read: focused window has no package (PopupWindow:3c1d2e5)"; lacks res/flow.xml "not in front"
verdict

app_case app-crash-dialog
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' '  mCurrentFocus=Window{c7b4574 u0 Application Error: com.example}' \
  '  mFocusedApp=ActivityRecord{e263aa3 u0 com.example/.Main t45}' > "$case_dir/adb/focus"
run_app
begin "app: the system's crash dialog is named, and not taken for the app in front"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app state not read: the system shows the crash dialog of com.example"; lacks res/flow.xml "running, in front"
verdict

app_case app-no-variant
run_flow "$case_dir/flow.json" YUKTI_CONFIG="$case_dir/cfg.json"
begin "app: no variant for the run - not checked, the result still written"
status_is 1; file_full res/flow.xml; red_is failure StepFailed 1 0
has res/flow.xml 'app: not checked - no variant for this run ($YUKTI_VARIANT is not set)'; not_asked "pidof com.example"
verdict

app_case app-no-config
run_flow "$case_dir/flow.json" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/none.json"
begin "app: a variant with no config - not checked, the result still written"
status_is 1; file_full res/flow.xml; red_is failure StepFailed 1 0
has res/flow.xml "app: not checked - no config at"; not_asked "pidof com.example"
verdict

app_case app-no-package
app_cfg android bundleId
run_app
begin "app: a variant with no package - not checked, the result still written"
status_is 1; file_full res/flow.xml; red_is failure StepFailed 1 0
has res/flow.xml "app: not checked - variant 'app' has no 'package' in"; not_asked "pidof com.example"
verdict

dev_case app-pass
app_cfg; screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
run_app
env ANDROID_HOME="$ROOT/tests/fake-sdk" FAKE_ADB_DIR="$case_dir/adb" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json" YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" \
  "$YUKTI" flow --check "$case_dir/flow.json" > /dev/null 2>&1
begin "app: a flow that passes, and --check, ask nothing about the app"
status_is 0; fake_used; not_asked "pidof com.example"; not_asked "logcat"; file_absent res/flow-crash.txt
verdict

app_case app-pidof-hangs
echo hang > "$case_dir/adb/app-pid"
t0=$SECONDS; run_app; took=$((SECONDS - t0))
begin "app: a device that does not answer is asked once, within the budget"
status_is 1; red_is failure StepFailed 1 0
[ "$took" -lt 40 ] || no "the run took ${took}s"
has res/flow.xml "app state not read: no answer in 10 s"; has res/flow.xml "crash log not read:"
not_asked "dumpsys window"; not_asked "logcat"
verdict

app_case app-screencap-hangs
echo hang > "$case_dir/adb/screencap"
run_app
begin "app: after a screenshot that never answered, the app is not asked about"
status_is 1; has res/flow.xml "app state not read: the device did not answer the screenshot"
not_asked "pidof com.example"; not_asked "logcat"
verdict

app_case app-crash-hangs
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' "$FRONT" > "$case_dir/adb/focus"; echo hang > "$case_dir/adb/crash"
run_app
begin "app: a crash log that does not come is not reported as no crash"
status_is 1; has res/flow.xml "crash log not read: no answer in 10 s"; lacks res/flow.xml "none since the flow started"
file_absent res/flow-crash.txt
verdict

app_case app-device-error
echo 4242 > "$case_dir/adb/app-pid"
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
rm -f "$case_dir/adb/app-pid"
run_app
begin "app: a device error stays an error, the app line is added"
status_is 1; red_is error DeviceError 0 1
has res/flow.xml "is not running: it was gone when the step failed"
verdict

app_case app-stopped-by-flow
flow_file "$case_dir/flow.json" '{ "do": "clearState", "value": "app" }' '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_app
begin "app: stopped by the flow itself is not a crash"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app: com.example not running - stopped by step 1"; lacks res/flow.xml "it was gone"
verdict

ios_case app-ios-gone
mkdir -p "$case_dir/xcrun" "$case_dir/reports"; app_cfg ios bundleId
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')"
printf 'PID\tStatus\tLabel\n-\t0\tcom.apple.springboard\n' > "$case_dir/xcrun/launchctl"
printf '{"bundleID":"com.example","exception":"EXC_CRASH"}\n' > "$case_dir/reports/Example-2026-10-19-234001.ips"
printf '{"bundleID":"com.example","exception":"OLD"}\n' > "$case_dir/reports/Example-old.ips"
touch -t 202001010000 "$case_dir/reports/Example-old.ips"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_ios "$case_dir/flow.json" PATH="$ROOT/tests/fake-sdk/xcrun-bin:$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun" YUKTI_IOS_CRASH_DIR="$case_dir/reports" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"
begin "app on iOS: gone in launchctl, the newest report of the run kept"
status_is 1; red_is failure AppGone 1 0
has res/flow.xml "the app com.example is not running: it was gone when the step failed"
file_full res/flow-crash.ips; has res/flow-crash.ips "EXC_CRASH"; lacks res/flow-crash.ips "OLD"
verdict

ios_case app-ios-running
mkdir -p "$case_dir/xcrun" "$case_dir/reports"; app_cfg ios bundleId
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')"
printf 'PID\tStatus\tLabel\n4242\t0\tUIKitApplication:com.example[1a2b][rb-legacy]\n' > "$case_dir/xcrun/launchctl"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_ios "$case_dir/flow.json" PATH="$ROOT/tests/fake-sdk/xcrun-bin:$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun" YUKTI_IOS_CRASH_DIR="$case_dir/reports" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"
begin "app on iOS: running - a note, and no report yet"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app: com.example running"; has res/flow.xml "crash log: no crash report yet in DiagnosticReports"
verdict

# ── Studio: the screen tree behind Inspect (#125) ───────────────────────────
# Studio read `yukti ui` only as idb's JSON and swallowed the error on a
# uiautomator dump, so on Android its element list was always empty. The
# reader is checked as functions (imported, no server) and through a live
# Studio on a free port, driving the same fakes the engine cases use.

# studio_py <python> - run python with Studio's module importable as `server`.
studio_py(){ "$PY3" -c "import sys; sys.path.insert(0, '$ROOT/studio'); import server
$1" > "$case_dir/out.txt" 2>&1; run_status=$?; }

# studio_get <route> [VAR=value...] - start Studio against this case's fakes,
# GET the route once, keep the answer in $case_dir/answer.json, stop Studio.
studio_get(){ local route="$1"; shift
  env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_DEVICE_PT_W -u YUKTI_DEVICE_PT_H \
    ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_HELPER=0 YUKTI_CONFIG="$case_dir/cfg.json" \
    FAKE_ADB_DIR="$case_dir/adb" FAKE_IDB_DIR="$case_dir/idb" TMPDIR="$case_dir/tmp" "$@" \
    "$PY3" - "$ROOT/studio/server.py" "$route" > "$case_dir/answer.json" 2> "$case_dir/out.txt" <<'PY'
import os, socket, subprocess, sys, time, urllib.error, urllib.request
srv, route = sys.argv[1:3]
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
p = subprocess.Popen([sys.executable, srv], env=dict(os.environ, YUKTI_STUDIO_PORT=str(port)),
                     stdout=subprocess.DEVNULL)
try:
    for _ in range(100):
        try:
            body = urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, route), timeout=60).read()
            break
        except urllib.error.URLError:
            time.sleep(0.1)
    else:
        sys.exit("Studio did not answer on port %d" % port)
    sys.stdout.write(body.decode("utf-8"))
finally:
    p.terminate(); p.wait()
PY
  run_status=$?; }

# answer <python expression over a, the answer> - one claim about the answer.
answer(){ "$PY3" -c "import json,sys; a=json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" \
  "$case_dir/answer.json" 2>/dev/null || no "answer is not: $1"; }

# A nested dump: a frame holding a tab with an id, a bare view, and a card with
# a button inside it. The bare view has neither id nor text and is still a node
# of the tree, as uiautomatorviewer shows it.
nested_dump(){ printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hierarchy rotation="0">' \
  '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" enabled="true" scrollable="false" bounds="[0,0][1080,2400]">' \
  '<node index="0" text="Today" resource-id="com.example:id/today-tab" class="android.widget.TextView" content-desc="" clickable="true" enabled="true" scrollable="false" bounds="[0,2200][540,2400]" />' \
  '<node index="1" text="" resource-id="" class="android.view.View" content-desc="" clickable="false" enabled="true" scrollable="false" bounds="[540,2200][1080,2400]" />' \
  '<node index="2" text="" resource-id="com.example:id/card" class="android.view.ViewGroup" content-desc="Water card" clickable="true" enabled="true" scrollable="false" bounds="[40,400][1040,800]">' \
  '<node index="0" text="Add" resource-id="com.example:id/card-add" class="android.widget.Button" content-desc="" clickable="true" enabled="false" scrollable="false" bounds="[800,600][1000,760]" />' \
  '</node></node></hierarchy>'; }

new_case studio-tree-dump
nested_dump > "$case_dir/dump.xml"
studio_py "
u, n = server.parse_tree(open('$case_dir/dump.xml').read())
assert u == 'px', u
assert len(n) == 5, len(n)
assert [x['id'] for x in n] == ['', 'today-tab', '', 'card', 'card-add'], [x['id'] for x in n]
assert n[1]['rid'] == 'com.example:id/today-tab' and n[1]['text'] == 'Today'
assert [x['parent'] for x in n] == [None, 0, 0, 0, 3] and [x['depth'] for x in n] == [0, 1, 1, 1, 2]
assert n[4]['bounds'] == [800, 600, 1000, 760] and n[4]['enabled'] is False and n[4]['clickable'] is True
assert n[3]['desc'] == 'Water card'
e = server.legacy_elements(n)
assert [(x['label'], x['x'], x['y']) for x in e] == [('Today', 270, 2300), ('Water card', 540, 600), ('Add', 900, 680)], e
print('tree ok')"
begin "studio: a uiautomator dump is a tree with ids, nesting and boxes in px"
status_is 0; has out.txt "tree ok"
verdict

new_case studio-tree-idb
tree "$case_dir/desc.json" "$(itext email 100 '"ada@example.com"')" \
  '{"type":"Button","AXUniqueId":"","AXLabel":"Sign in","AXValue":null,"enabled":true,"frame":{"x":40.5,"y":200,"width":300,"height":44}}'
studio_py "
u, n = server.parse_tree(open('$case_dir/desc.json').read())
assert u == 'pt', u
assert [(x['id'], x['text'], x['desc'], x['cls']) for x in n] == [('email', '', 'ada@example.com', 'TextField'), ('', 'Sign in', '', 'Button')], n
assert n[1]['bounds'] == [40.5, 200, 340.5, 244] and n[1]['enabled'] is True
assert [x['depth'] for x in n] == [0, 0] and [x['parent'] for x in n] == [None, None]
# The old list, exactly as before: AXLabel, else AXValue, and the centre.
assert [(x['label'], x['type'], x['x'], x['y']) for x in server.legacy_elements(n)] == [('ada@example.com', 'TextField', 190, 120), ('Sign in', 'Button', 190, 222)]
print('idb ok')"
begin "studio: an idb tree is a flat list with AXUniqueId as the id, boxes in pt"
status_is 0; has out.txt "idb ok"
verdict

new_case studio-tree-garbage
studio_py "
for raw, word in (('<hierarchy><node', 'does not parse'), ('[{', 'does not parse'), ('{}', 'neither'), ('error: no device', 'neither')):
    try:
        server.parse_tree(raw)
    except ValueError as e:
        assert word in str(e), (raw, str(e))
    else:
        raise AssertionError('parsed: %r' % raw)
a = server.ui_answer(0, '<hierarchy><node', '')
assert a['outcome'] == 'not_read' and 'does not parse' in a['error'] and a['elements'] == [], a
assert server.ui_answer(0, '', '')['outcome'] == 'empty'
assert server.ui_answer(0, '<hierarchy rotation=\"0\"></hierarchy>', '')['outcome'] == 'empty'
print('garbage ok')"
begin "studio: an answer it cannot read is not_read with the reason, never an empty screen"
status_is 0; has out.txt "garbage ok"
verdict

new_case studio-pick
nested_dump > "$case_dir/dump.xml"
studio_py "
u, n = server.parse_tree(open('$case_dir/dump.xml').read())
pick = lambda x, y: (server.pick_at(n, x, y) or {}).get('i')
assert pick(900, 700) == 4      # the button, not the card or the frame around it
assert pick(100, 500) == 3      # the card
assert pick(700, 2300) == 2     # the bare view: no id, no text, still the node there
assert pick(540, 2300) == 2     # left edge belongs to the box ...
assert pick(539, 2300) == 1     # ... the right edge does not
assert pick(1080, 100) is None  # past the right edge of the screen
z = [dict(n[0], i=0, bounds=[0, 0, 0, 0]), dict(n[0], i=1, depth=1, bounds=[10, 10, 20, 20]), dict(n[0], i=2, depth=2, bounds=[10, 10, 20, 20]), dict(n[0], i=3, depth=2, bounds=[10, 10, 20, 20])]
assert server.pick_at(z, 0, 0) is None             # an empty box is never picked
assert server.pick_at(z, 15, 15)['i'] == 3         # a tie: deeper, then later
print('pick ok')"
begin "studio: the node under a point is the smallest box holding it"
status_is 0; has out.txt "pick ok"
verdict

dev_case studio-ui-android
nested_dump > "$case_dir/adb/dump-1.xml"
studio_get /api/ui YUKTI_PLATFORM=android
begin "studio: /api/ui on Android reads the dump - nodes, units, and the old list"
status_is 0; fake_used
answer 'a["outcome"] == "ok" and a["ok"] is True and a["units"] == "px"'
answer '[n["id"] for n in a["nodes"]] == ["", "today-tab", "", "card", "card-add"]'
answer '[e["label"] for e in a["elements"]] == ["Today", "Water card", "Add"]'
answer 'a["raw"].startswith("<?xml")'
verdict

ios_case studio-ui-ios
tree "$case_dir/idb/desc-1.json" "$(itext email 100 '"ada@example.com"')"
studio_get /api/ui YUKTI_PLATFORM=ios PATH="$ROOT/tests/fake-sdk/idb-bin:$PATH"
begin "studio: /api/ui on iOS - the old list as before, and the id from AXUniqueId"
status_is 0
answer 'a["outcome"] == "ok" and a["units"] == "pt"'
answer 'a["elements"] == [{"label": "ada@example.com", "type": "TextField", "x": 190, "y": 120}]'
answer '[n["id"] for n in a["nodes"]] == ["email"]'
[ -s "$case_dir/idb/log" ] || no "the fake idb was never called"
verdict

ios_case studio-inspect-ios
mkdir -p "$case_dir/xcrun"
tree "$case_dir/idb/desc-1.json" "$(itext email 100 '"ada@example.com"')"
studio_get /api/inspect YUKTI_PLATFORM=ios PATH="$ROOT/tests/fake-sdk/xcrun-bin:$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun"
begin "studio: /api/inspect on iOS - simulator screenshot, idb tree, boxes in the device's points"
status_is 0
answer '__import__("base64").b64decode(a["png"]).startswith(b"\x89PNG")'
answer 'a["outcome"] == "ok" and a["units"] == "pt" and (a["pt_w"], a["pt_h"]) == (402, 874)'
answer '[n["id"] for n in a["nodes"]] == ["email"]'
has xcrun/log "screenshot"
[ -s "$case_dir/idb/log" ] || no "the fake idb was never called"
verdict

dev_case studio-ui-not-read
: > "$case_dir/adb/running"     # a helper holds the device: every dump comes back empty
studio_get /api/ui YUKTI_PLATFORM=android
begin "studio: /api/ui when the screen cannot be read - not_read with the engine's reason"
status_is 0; fake_used
answer 'a["outcome"] == "not_read" and a["ok"] is False and a["elements"] == [] and a["nodes"] == []'
answer '"uiautomator produced no usable dump" in a["error"] and "\x1b" not in a["error"]'
verdict

dev_case studio-inspect-android
nested_dump > "$case_dir/adb/dump-1.xml"
studio_get /api/inspect YUKTI_PLATFORM=android
begin "studio: /api/inspect - the screenshot and the tree in one answer"
status_is 0; fake_used
answer '__import__("base64").b64decode(a["png"]).startswith(b"\x89PNG")'
answer 'a["outcome"] == "ok" and a["units"] == "px" and len(a["nodes"]) == 5 and "raw" not in a'
answer 'all(k in a for k in ("png_w", "png_h", "pt_w", "pt_h"))'
has adb/log "exec-out screencap"
verdict

dev_case studio-inspect-no-shot
nested_dump > "$case_dir/adb/dump-1.xml"
echo fail > "$case_dir/adb/screencap"
studio_get /api/inspect YUKTI_PLATFORM=android
begin "studio: /api/inspect without a screenshot - not_read, and no tree read for it"
status_is 0; fake_used
answer 'a["outcome"] == "not_read" and a["error"] and "png" not in a'
lacks adb/log "uiautomator dump"
verdict

# ── a text check limited to one element: "in" (#102) ────────────────────────
# The screen of the issue: a greeting with its own id and, elsewhere on the
# screen, a card whose text also holds the name. A check written without "in"
# passes on the card; with "in" only the greeting and what lies within it count.
# tnode <id> <text> <x1,y1,x2,y2> - a node at a given place; an empty id is none.
tnode(){ printf '<node index="0" text="%s" resource-id="%s" class="android.widget.TextView" package="com.example" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[%s][%s]" />' \
  "$2" "${1:+com.example:id/$1}" "$(printf '%s' "$3" | cut -d, -f1-2)" "$(printf '%s' "$3" | cut -d, -f3-4)"; }
IN_ROOT="$(tnode "" "" 0,0,1080,2400)"
IN_BOX="$(tnode greeting "" 0,100,1080,300)"
IN_HI="$(tnode "" "Good morning, Ada!" 40,150,1040,250)"
IN_BARE="$(tnode "" "Good morning!" 40,150,1040,250)"
IN_CARD="$(tnode "" "Ada, your plan is ready" 40,900,1040,1000)"

dev_case in-pass
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_BOX" "$IN_HI" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": ", Ada!", "match": "contains", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: the text inside the element passes"
status_is 0; fake_used; has out.txt "assert (contains) in 'greeting': ', Ada!' on screen at 540 200"
verdict

# The false green of the issue: without "in" the card answers for the greeting.
dev_case in-control
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_BOX" "$IN_BARE" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "match": "contains" }'
run_flow "$case_dir/flow.json"
begin "in: without it, the text of another element passes (the case for the key)"
status_is 0; has out.txt "assert (contains): 'Ada' on screen at 540 950"
verdict

dev_case in-elsewhere
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_BOX" "$IN_BARE" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "match": "contains", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: the same text in another element does not count"
status_is 1; has out.txt "assert FAILED (contains match): 'Ada' not in the element with id 'greeting'"
verdict

# The element itself is a candidate: a text view that carries the id and the text.
dev_case in-self
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$(tnode greeting "Good morning, Ada!" 0,100,1080,300)" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Good morning, Ada!", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: the element named by id may hold the text itself"
status_is 0; has out.txt "assert (exact) in 'greeting'"
verdict

dev_case in-no-id
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_HI" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "match": "contains", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: a missing element is named in the words of tapId"
status_is 1; has out.txt "assert FAILED: no element with id 'greeting'"
verdict

# A namesake of zero size is not the element: the next one with the id is.
dev_case in-zero-namesake
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$(tnode greeting "" 500,50,500,50)" "$IN_BOX" "$IN_HI"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": ", Ada!", "match": "contains", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: an element of zero size is skipped for the next one with the id"
status_is 0; has out.txt "on screen at 540 200"
verdict

dev_case in-not-pass
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_BOX" "$IN_BARE" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertNotText", "value": "Ada", "match": "contains", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: assertNotText ignores the same text in another element"
status_is 0; has out.txt "assertNot (contains) in 'greeting': 'Ada' not in that element"
verdict

dev_case in-not-fail
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_BOX" "$IN_HI"
flow_file "$case_dir/flow.json" '{ "do": "assertNotText", "value": "Ada", "match": "contains", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: assertNotText fails on the text inside the element"
status_is 1; has out.txt "assertNot FAILED (contains match): 'Ada' IS in the element with id 'greeting', at 540 200"
verdict

dev_case in-not-no-id
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertNotText", "value": "Ada", "match": "contains", "in": "greeting" }'
run_flow "$case_dir/flow.json"
begin "in: assertNotText cannot pass on an element that is not there"
status_is 1; has out.txt "assertNot FAILED: no element with id 'greeting'"
verdict

dev_case in-wait-arrives
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_CARD"
screen "$case_dir/adb/dump-2.xml" "$IN_ROOT" "$IN_BOX" "$IN_BARE" "$IN_CARD"
screen "$case_dir/adb/dump-3.xml" "$IN_ROOT" "$IN_BOX" "$IN_HI" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "waitFor", "value": ", Ada!", "match": "contains", "in": "greeting", "timeout": 5 }'
run_flow "$case_dir/flow.json"
begin "in: waitFor keeps polling through a missing element and a text not yet in it"
status_is 0; has out.txt "waitFor (contains match) in 'greeting': ', Ada!' on screen at 540 200"
reads_are 3
verdict

dev_case in-wait-elsewhere
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_BOX" "$IN_BARE" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "waitFor", "value": "Ada", "match": "contains", "in": "greeting", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "in: waitFor times out naming the element that is there without the text"
status_is 1; has out.txt "'Ada' not on screen after 1s - not in the element with id 'greeting'"
verdict

dev_case in-wait-no-id
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IN_CARD"
flow_file "$case_dir/flow.json" '{ "do": "waitFor", "value": "Ada", "match": "contains", "in": "greeting", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "in: waitFor times out naming the missing element"
status_is 1; has out.txt "'Ada' not on screen after 1s - no element with id 'greeting'"
verdict

# iOS: the same contract by frame and accessibility identifier.
ilabel(){ printf '{"type":"StaticText","role_description":"text","AXUniqueId":"%s","AXLabel":"%s","frame":{"x":%s,"y":%s,"width":%s,"height":%s}}' "$1" "$2" $(printf '%s' "$3" | tr , ' '); }
I_BOX="$(ilabel greeting "" 0,60,402,100)"
I_HI="$(ilabel "" "Good morning, Ada!" 20,80,360,40)"
I_BARE="$(ilabel "" "Good morning!" 20,80,360,40)"
I_CARD="$(ilabel "" "Ada, your plan is ready" 20,400,360,40)"

ios_case ios-in-pass
tree "$case_dir/idb/desc-1.json" "$IAPP" "$I_BOX" "$I_HI" "$I_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": ", Ada!", "match": "contains", "in": "greeting" }'
run_ios "$case_dir/flow.json"
begin "in on iOS: the text inside the element passes"
status_is 0; has out.txt "assert (contains) in 'greeting': ', Ada!' on screen at 200 100"
verdict

ios_case ios-in-elsewhere
tree "$case_dir/idb/desc-1.json" "$IAPP" "$I_BOX" "$I_BARE" "$I_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "match": "contains", "in": "greeting" }'
run_ios "$case_dir/flow.json"
begin "in on iOS: the same text in another element does not count"
status_is 1; has out.txt "'Ada' not in the element with id 'greeting'"
verdict

# State by id on iOS (#103): the Selected trait, the checked word in the value.
istate(){ printf '{"type":"%s","role_description":"%s","AXUniqueId":"%s","AXLabel":"%s","AXValue":"%s","traits":%s,"frame":{"x":20,"y":%s,"width":360,"height":44}}' \
  "$2" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" "$1" "$1" "$4" "$5" "$3"; }

ios_case ios-state-selected
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate day Button 200 "" '["Button"]')" "$(istate week Button 300 "" '["Button","Selected"]')"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "week", "selected": true }' '{ "do": "assertId", "value": "day", "selected": false }' '{ "do": "assertId", "value": "day", "selected": true }'
run_ios "$case_dir/flow.json"
begin "assertId selected on iOS: the Selected trait, and the same flow red on the other tab"
status_is 1; has out.txt "'week' on screen at 200 322, selected"; has out.txt "'day' on screen at 200 222, not selected"
has out.txt "assert FAILED: 'day' is not selected"
verdict

ios_case ios-state-checked
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate remind Switch 200 1 '["Button"]')" "$(istate agree Other 300 'checkbox, checked' '[]')" \
  "$(istate items Other 500 'unchecked, 5 items' '[]')" "$(istate plain Other 400 "" '[]')"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "remind", "checked": true }' '{ "do": "assertId", "value": "agree", "checked": true }' \
  '{ "do": "assertId", "value": "items", "checked": false }' '{ "do": "assertId", "value": "plain", "checked": false }'
run_ios "$case_dir/flow.json"
begin "assertId checked on iOS: a switch by 1, a checkbox by the part of its value, no state fails by name"
status_is 1; has out.txt "'remind' on screen at 200 222, checked"; has out.txt "'agree' on screen at 200 322, checked"
has out.txt "'items' on screen at 200 522, not checked"
has out.txt "assert FAILED: 'plain' has no checked state"
verdict

ios_case ios-in-no-id
tree "$case_dir/idb/desc-1.json" "$IAPP" "$I_HI" "$I_CARD"
flow_file "$case_dir/flow.json" '{ "do": "assertNotText", "value": "Ada", "match": "contains", "in": "greeting" }'
run_ios "$case_dir/flow.json"
begin "in on iOS: a missing element is named in the words of tapId"
status_is 1; has out.txt "assertNot FAILED: no element with id 'greeting'"
verdict

# The builder.
new_case in-check
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "in": "${YUKTI_TEST_IN}" }' \
  '{ "do": "assertNotText", "value": "Ada", "in": "greeting" }' '{ "do": "waitFor", "value": "Ada", "in": "greeting" }'
expect "check: in on the three text checks builds, a variable filled" 0 " - 3 steps" \
  env YUKTI_TEST_IN=greeting "$YUKTI" flow --check "$case_dir/flow.json"

new_case shows-check
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!", "shows": "${YUKTI_TEST_SHOWS}" }' \
  '{ "do": "type", "value": "5", "shows": 5 }'
expect "check: shows on type builds, a variable filled, a number taken as text" 0 " - 2 steps" \
  env YUKTI_TEST_SHOWS=12 "$YUKTI" flow --check "$case_dir/flow.json"

new_case shows-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "amount", "shows": "12" }'
expect "check: shows on a step that does not take it is refused" 1 \
  "step 1 'tapId': step 'tapId' does not take \"shows\" - only type does" check "$case_dir/flow.json"

new_case shows-empty
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "ab", "shows": "" }'
expect "check: an empty shows is refused" 1 \
  "step 1 'type': \"shows\" is empty - a field that shows nothing new cannot be told from a field the keys never reached" check "$case_dir/flow.json"

new_case shows-not-text
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "12a!", "shows": ["12"] }'
expect "check: a shows that is not text is refused" 1 \
  "step 1 'type': \"shows\" is the text the field holds once the value is typed" check "$case_dir/flow.json"

new_case state-check
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "week", "selected": true, "checked": false }' '{ "do": "waitForId", "value": "week", "selected": true }'
expect "check: selected and checked on assertId and waitForId build" 0 " - 2 steps" check "$case_dir/flow.json"

new_case state-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "week", "selected": true }'
expect "check: a state on a step that does not take it is refused" 1 \
  "step 1 'tapId': step 'tapId' does not take \"selected\" - only assertId, waitForId do" check "$case_dir/flow.json"

new_case state-not-bool
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "week", "checked": "false" }'
expect "check: a state that is not true or false is refused" 1 \
  "step 1 'assertId': \"checked\" is true or false, got \"false\"" check "$case_dir/flow.json"

new_case in-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "Ada", "in": "greeting" }'
expect "check: in on a step that does not take it is refused" 1 \
  "step 1 'tapId': step 'tapId' does not take \"in\" - only assertText, assertNotText, waitFor, tapText, assertCount, assertCountId do" check "$case_dir/flow.json"

new_case tap-in-timeout
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note", "timeout": 5 }'
expect "check: tapText with in does not scroll, so a timeout with it is refused" 1 \
  "step 1 'tapText' takes \"in\" or \"timeout\", not both" check "$case_dir/flow.json"

new_case in-empty
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "in": " " }'
expect "check: an empty in is refused" 1 \
  "step 1 'assertText': \"in\" is empty - name the id of the element or drop the key" check "$case_dir/flow.json"

new_case in-not-text
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "in": { "id": "greeting" } }'
expect "check: an in that is not text is refused" 1 \
  "step 1 'assertText': \"in\" is the id of the element the text has to be in" check "$case_dir/flow.json"

new_case in-unset-var
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Ada", "in": "${YUKTI_TEST_IN}" }'
expect "check: an in with a variable that is not set is refused" 1 \
  "\$YUKTI_TEST_IN is not set" env -u YUKTI_TEST_IN "$YUKTI" flow --check "$case_dir/flow.json"

# ── a link that is part of a longer text: tapText with "in" (#146) ─────────
# A note whose last words are a link. React Native gives the nested Text with
# accessibilityRole="link" a virtual node of its own: no resource id, the link's
# words as content-desc, its own bounds, clickable - by the React Native source,
# not measured yet. Without the role the note is one TextView and the link has
# no bounds at all (measured, Android 15).
# lnode <desc> <x1,y1,x2,y2> - such a virtual node.
lnode(){ printf '<node index="0" text="" resource-id="" class="android.view.View" package="com.example" content-desc="%s" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[%s][%s]" />' \
  "$1" "$(printf '%s' "$2" | cut -d, -f1-2)" "$(printf '%s' "$2" | cut -d, -f3-4)"; }
LN_TEXT="By continuing you agree to the Terms of Use and the Privacy Policy."
LN_NOTE="$(tnode consent-note "$LN_TEXT" 40,1000,1040,1200)"
LN_LINK="$(lnode "Terms of Use" 400,1120,900,1180)"

dev_case tap-in-link
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$LN_NOTE" "$LN_LINK"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: the link's own node inside the note takes the tap, not the note's centre"
status_is 0; has out.txt "tap 'Terms of Use' in 'consent-note'"; has adb/log "input tap 650 1150"; lacks adb/log "input tap 540 1100"
verdict

# The node order does not decide it: the link listed before the note still wins.
dev_case tap-in-link-first
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$LN_LINK" "$LN_NOTE"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "terms of use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: the link wins whatever the order of the nodes, case folded as tapText always does"
status_is 0; has adb/log "input tap 650 1150"
verdict

# The false green of the issue: without "in" and without the link's node the
# centre of the note is tapped and the step passes.
dev_case tap-in-control
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$LN_NOTE"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use" }'
run_flow "$case_dir/flow.json"
begin "tapText in: without it, the words inside the note tap the note's centre (the case for the key)"
status_is 0; has adb/log "input tap 540 1100"
verdict

dev_case tap-in-no-node
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$LN_NOTE"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: words with no element of their own fail by name, nothing is tapped"
status_is 1; has out.txt "'Terms of Use' is part of a longer text in the element with id 'consent-note' and has no element of its own to tap"
has out.txt 'accessibilityRole="link"'; lacks adb/log "input tap"
verdict

dev_case tap-in-elsewhere
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$(tnode consent-note "By continuing you agree." 40,1000,1040,1200)" "$(lnode "Terms of Use" 400,1520,900,1580)"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: the same words outside the element do not count"
status_is 1; has out.txt "no element matching 'Terms of Use' on the screen in the element with id 'consent-note'"; lacks adb/log "input tap"
verdict

dev_case tap-in-no-id
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$(tnode "" "$LN_TEXT" 40,1000,1040,1200)" "$LN_LINK"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: a missing element is named in the words of tapId"
status_is 1; has out.txt "no element with id 'consent-note'"; lacks adb/log "input tap"
verdict

# The element is a candidate when its whole text is the value: a button inside
# a card, named by the card, is still tapped.
dev_case tap-in-whole
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$(tnode consent-note "Terms of Use" 40,1000,1040,1200)"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: the element itself is tapped when its whole text is the value"
status_is 0; has adb/log "input tap 540 1100"
verdict

# The id on a view around the text, not on the text: the text inside it is a
# longer text all the same, and its centre is not the link.
dev_case tap-in-wrapper
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$(tnode consent-note "" 20,980,1060,1220)" "$(tnode "" "$LN_TEXT" 40,1000,1040,1200)"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: an id on a view around the text does not turn the text's centre into the link"
status_is 1; has out.txt "has no element of its own to tap"; lacks adb/log "input tap"
verdict

# The id on a view around the text, and the link has its node: the link is tapped.
dev_case tap-in-wrapper-link
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$(tnode consent-note "" 20,980,1060,1220)" "$(tnode "" "$LN_TEXT" 40,1000,1040,1200)" "$LN_LINK"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: an id on a view around the text, the link inside it takes the tap"
status_is 0; has adb/log "input tap 650 1150"
verdict

# Two links with the same words: the first in the tree, as equal matches always go.
dev_case tap-in-tie
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$LN_NOTE" "$(lnode "Terms of Use" 60,1020,360,1080)" "$LN_LINK"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: of two links with the same words the first in the tree takes the tap"
status_is 0; has adb/log "input tap 210 1050"; lacks adb/log "input tap 650 1150"
verdict

# The link has its node and the node has no size: not a missing role.
dev_case tap-in-zero-link
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$LN_NOTE" "$(lnode "Terms of Use" 400,1120,400,1120)"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_flow "$case_dir/flow.json"
begin "tapText in: a link node of no size is not on the screen, and the message does not blame the role"
status_is 1; has out.txt "no element matching 'Terms of Use' on the screen in the element with id 'consent-note'"; lacks out.txt "accessibilityRole"; lacks adb/log "input tap"
verdict

# iOS: the link is an element with its own frame (RCTParagraphComponentAccessibilityProvider).
# Written from the React Native source, not measured on a simulator yet.
ilnote='{"type":"StaticText","role_description":"text","AXUniqueId":"consent-note","AXLabel":"By continuing you agree to the Terms of Use and the Privacy Policy.","frame":{"x":20,"y":500,"width":350,"height":80}}'
illink='{"type":"Link","role_description":"link","AXUniqueId":null,"AXLabel":"Terms of Use","frame":{"x":150,"y":550,"width":160,"height":20}}'
iroot='{"type":"Application","role_description":"application","AXUniqueId":null,"AXLabel":"App","frame":{"x":0,"y":0,"width":402,"height":874}}'

ios_case ios-tap-in-link
tree "$case_dir/idb/desc-1.json" "$iroot" "$ilnote" "$illink"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_ios "$case_dir/flow.json"
begin "tapText in on iOS: the link's own element takes the tap"
status_is 0; has idb/log "ui tap --udid FAKE-UDID 230 560"
verdict

ios_case ios-tap-in-no-node
tree "$case_dir/idb/desc-1.json" "$iroot" "$ilnote"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_ios "$case_dir/flow.json"
begin "tapText in on iOS: words with no element of their own fail by name"
status_is 1; has out.txt "has no element of its own to tap"; lacks idb/log "ui tap "
verdict

ios_case ios-tap-in-wrapper
tree "$case_dir/idb/desc-1.json" "$iroot" '{"type":"Other","role_description":"group","AXUniqueId":"consent-note","AXLabel":null,"frame":{"x":10,"y":490,"width":370,"height":100}}' "$(printf '%s' "$ilnote" | sed 's/"AXUniqueId":"consent-note"/"AXUniqueId":null/')"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_ios "$case_dir/flow.json"
begin "tapText in on iOS: an id on a view around the text does not turn the text's centre into the link"
status_is 1; has out.txt "has no element of its own to tap"; lacks idb/log "ui tap "
verdict

ios_case ios-tap-in-zero-link
tree "$case_dir/idb/desc-1.json" "$iroot" "$ilnote" '{"type":"Link","role_description":"link","AXUniqueId":null,"AXLabel":"Terms of Use","frame":{"x":150,"y":550,"width":0,"height":0}}'
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note" }'
run_ios "$case_dir/flow.json"
begin "tapText in on iOS: a link of no size is not on the screen, and the message does not blame the role"
status_is 1; has out.txt "no element matching 'Terms of Use' on the screen in the element with id 'consent-note'"; lacks out.txt "accessibilityRole"; lacks idb/log "ui tap "
verdict

# ── setPermission (#51) ─────────────────────────────────────────────────────
# perm_case <name> - an Android case with a config whose variant "app" is
# com.example, and a manifest that asks for notifications, camera and fine
# location; a case rewrites `requested` or `sdk` when it needs another device.
perm_case(){ dev_case "$1"
  printf '%s' '{"platform":"android","variants":{"app":{"platform":"android","package":"com.example"}}}' > "$case_dir/cfg.json"
  printf '%s\n' android.permission.INTERNET android.permission.POST_NOTIFICATIONS android.permission.CAMERA \
    android.permission.ACCESS_FINE_LOCATION android.permission.health.READ_STEPS android.permission.health.READ_HEART_RATE > "$case_dir/adb/requested"; }
run_perm(){ run_flow "$1" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"; }

perm_case perm-denied
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "notifications", "state": "denied" }'
run_perm "$case_dir/flow.json"
begin "setPermission: denied revokes and marks it user-fixed, so the app is not asked again"
status_is 0; has out.txt "permission notifications denied for com.example"
has adb/log "shell pm revoke com.example android.permission.POST_NOTIFICATIONS; pm set-permission-flags com.example android.permission.POST_NOTIFICATIONS user-set user-fixed"
verdict

perm_case perm-granted
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: granted clears the flags and grants"
status_is 0; has adb/log "shell pm clear-permission-flags com.example android.permission.CAMERA user-set user-fixed; pm grant com.example android.permission.CAMERA"
verdict

perm_case perm-unset
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "unset" }'
run_perm "$case_dir/flow.json"
begin "setPermission: unset revokes and clears the flags, so the dialog comes up again"
status_is 0; has adb/log "shell pm revoke com.example android.permission.CAMERA; pm clear-permission-flags com.example android.permission.CAMERA user-set user-fixed"
verdict

# Location is fine and coarse; the app asks for fine only, and only fine is set.
perm_case perm-several
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "location", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: a name of several permissions sets the ones the manifest asks for"
status_is 0; has adb/log "pm grant com.example android.permission.ACCESS_FINE_LOCATION"; lacks adb/log "ACCESS_COARSE_LOCATION"
verdict

# The partial grant of the issue: steps allowed, heart rate refused.
perm_case perm-partial
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "android.permission.health.READ_STEPS", "state": "granted" }' \
  '{ "do": "setPermission", "value": "android.permission.health.READ_HEART_RATE", "state": "denied" }'
run_perm "$case_dir/flow.json"
begin "setPermission: Android names with a dot write a partial grant"
status_is 0; has adb/log "pm grant com.example android.permission.health.READ_STEPS"; has adb/log "pm revoke com.example android.permission.health.READ_HEART_RATE"
verdict

perm_case perm-health
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "health", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: health sets every Health Connect permission the app asks for"
status_is 0; has out.txt "(2: android.permission.health.READ_STEPS android.permission.health.READ_HEART_RATE)"
verdict

perm_case perm-not-asked
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "microphone", "state": "denied" }'
run_perm "$case_dir/flow.json"
begin "setPermission: a permission the manifest does not ask for fails by name"
status_is 1; has out.txt "setPermission: 'com.example' does not ask for microphone (android.permission.RECORD_AUDIO)"; lacks adb/log "pm revoke"
verdict

perm_case perm-refused
printf '%s\n' 'Exception occurred while executing: java.lang.SecurityException: grant' > "$case_dir/adb/pm-refuses"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: pm's refusal in words is a failure, whatever its exit status"
status_is 1; has out.txt "the device refused android.permission.CAMERA for 'com.example': Exception occurred"
verdict

perm_case perm-old-android
echo 31 > "$case_dir/adb/sdk"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "notifications", "state": "denied" }' '{ "do": "launch", "value": "app" }'
run_perm "$case_dir/flow.json"
begin "setPermission: a permission older Android does not have skips the rest of the flow, out loud"
status_is 0; has out.txt "skipped: platform: notifications are a permission from Android 13 (API 33), this device is API 31 - the rest of the flow is skipped with it"
has out.txt "step 2 'launch' skipped: platform:"; lacks adb/log "pm revoke"; lacks adb/log "monkey"
has res/flow.xml '<skipped message="platform: notifications are a permission'; lacks res/flow.xml "condition not met"
has out.txt "flow skipped from step 1: platform:"; lacks out.txt "flow complete"
verdict

# Before Android 13 pm has no permission flags: a grant still works...
perm_case perm-old-granted
echo 31 > "$case_dir/adb/sdk"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: before Android 13 a grant is a plain pm grant"
status_is 0; has adb/log "shell pm grant com.example android.permission.CAMERA"; lacks adb/log "permission-flags"
verdict

# ...and denied, which lives in those flags, is skipped by name.
perm_case perm-old-denied
echo 32 > "$case_dir/adb/sdk"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "denied" }'
run_perm "$case_dir/flow.json"
begin "setPermission: before Android 13 denied is skipped, not half done"
status_is 0; has out.txt "platform: denied needs pm set-permission-flags, from Android 13 (API 33), this device is API 32"; lacks adb/log "pm revoke"
verdict

perm_case perm-reminders
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "reminders", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: reminders on Android is a platform skip"
status_is 0; has res/flow.xml 'message="platform: Android has no reminders permission"'
verdict

# The state is read back: a pm that answers nothing and changes nothing fails.
perm_case perm-not-taken
: > "$case_dir/adb/pm-ignores"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: a permission that did not take the state is a failure, read back from the device"
status_is 1; has out.txt "setPermission: the device does not hold granted for 'com.example' after the step - android.permission.CAMERA: not granted"
lacks res/flow.xml "AppGone"
verdict

# A denied permission set to unset loses its flags as well as its grant.
perm_case perm-denied-then-unset
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "denied" }' '{ "do": "setPermission", "value": "camera", "state": "unset" }'
run_perm "$case_dir/flow.json"
begin "setPermission: unset after denied clears what denied left"
status_is 0; has out.txt "permission camera unset for com.example"
verdict

# A work profile lists the app's permissions again under User 10; pm without
# --user acts on User 0, and that is the one read back.
perm_case perm-work-profile
: > "$case_dir/adb/user10"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: the read back is User 0, not a work profile listed after it"
status_is 0; has out.txt "permission camera granted for com.example"
verdict

perm_case perm-health-old
echo 33 > "$case_dir/adb/sdk"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "health", "state": "granted" }' '{ "do": "launch", "value": "app" }'
run_perm "$case_dir/flow.json"
begin "setPermission: health before Android 14 skips the rest of the flow"
status_is 0; has out.txt "platform: health is a permission of the system from Android 14 (API 34), this device is API 33"
has out.txt "flow skipped from step 1"; lacks adb/log "pm grant"; lacks adb/log "monkey"
verdict

perm_case perm-motion-old
echo 28 > "$case_dir/adb/sdk"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "motion", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: motion before Android 10 is a platform skip"
status_is 0; has out.txt "platform: motion is a permission from Android 10 (API 29), this device is API 28"
verdict

perm_case perm-not-installed
: > "$case_dir/adb/requested"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: a package the device lists no permissions for asks whether it is installed"
status_is 1; has out.txt "the device lists no permissions for 'com.example' - is it installed?"
verdict

# On a device dumpsys goes on for thousands of lines after the manifest; the
# reader of the list must take them all, or tr fails on the full pipe and
# pipefail throws the list away (#168).
perm_case perm-long-dumpsys
echo 3000 > "$case_dir/adb/filler"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: the manifest is found when dumpsys goes on for more than a pipe holds"
status_is 0; has out.txt "permission camera granted for com.example"; lacks out.txt "is it installed?"
verdict

perm_case perm-health-not-asked
printf '%s\n' android.permission.INTERNET android.permission.CAMERA > "$case_dir/adb/requested"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "health", "state": "granted" }'
run_perm "$case_dir/flow.json"
begin "setPermission: health the app does not ask for is named once"
status_is 1; has out.txt "'com.example' does not ask for health - its manifest"; lacks out.txt "health (health)"
verdict

perm_case perm-skip-in-include
flow_file "$case_dir/inc.json" '{ "do": "setPermission", "value": "reminders", "state": "granted" }' '{ "do": "wait", "value": "1" }'
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "inc.json" }' '{ "do": "wait", "value": "1", "when": { "platform": "android" } }' '{ "do": "launch", "value": "app" }'
run_perm "$case_dir/flow.json"
begin "setPermission: a platform skip inside a block skips the rest of the flow, numbered through"
status_is 0; has out.txt "step 2 'wait' skipped: platform:"; has out.txt "step 3 'wait' skipped: platform:"
has out.txt "step 4 'launch' skipped: platform:"; has out.txt "flow skipped from step 1"; lacks adb/log "monkey"
verdict

# A grant leaves a running app running: a failure after it still looks for a
# crash. A revoke stops the app, and the failure names that step instead.
perm_case perm-grant-not-a-stop
flow_file "$case_dir/flow.json" '{ "do": "launch", "value": "app" }' '{ "do": "setPermission", "value": "camera", "state": "granted" }' '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_perm "$case_dir/flow.json"
begin "setPermission: a grant after launch is not where the app stopped"
status_is 1; lacks res/flow.xml "stopped by step"; has res/flow.xml "it was gone when the step failed"
verdict

perm_case perm-revoke-is-a-stop
flow_file "$case_dir/flow.json" '{ "do": "launch", "value": "app" }' '{ "do": "setPermission", "value": "camera", "state": "denied" }' '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_perm "$case_dir/flow.json"
begin "setPermission: denied after launch is where the app stopped, not a crash"
status_is 1; has res/flow.xml "app: com.example not running - stopped by step 2"; lacks res/flow.xml "it was gone"
verdict

perm_case perm-state-on-assert
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "week", "selected": true, "state": "granted" }'
expect "check: a state on another step is refused even next to selected" 1 \
  "step 'assertId' does not take \"state\" - only setPermission does" check "$case_dir/flow.json"

perm_case perm-no-variant
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "denied" }'
run_flow "$case_dir/flow.json" YUKTI_CONFIG="$case_dir/cfg.json"
begin "setPermission: a run with no variant does not know whose permission it is"
status_is 1; has out.txt "setPermission: this run does not know which app 'camera' is for"
verdict

new_case perm-check-state
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "allowed" }'
expect "check: a state that is not granted, denied or unset is refused" 1 \
  "\"state\" is granted, denied, unset, got \"allowed\"" check "$case_dir/flow.json"

new_case perm-check-name
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camra", "state": "granted" }'
expect "check: a permission the engine does not know is refused" 1 \
  "'camra' is not a permission the engine knows" check "$case_dir/flow.json"

new_case perm-check-no-state
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera" }'
expect "check: setPermission without a state is refused" 1 \
  "\"state\" is granted, denied, unset, got nothing" check "$case_dir/flow.json"

new_case perm-check-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "launch", "value": "app", "state": "granted" }'
expect "check: a state on another step is refused" 1 \
  "step 'launch' does not take \"state\" - only setPermission does" check "$case_dir/flow.json"

# iOS: simctl privacy for what it covers, applesimutils for camera,
# notifications and health. Written from the documentation, not measured.
iperm_case(){ ios_case "$1"; mkdir -p "$case_dir/xcrun"
  printf '%s' '{"platform":"ios","variants":{"app":{"platform":"ios","bundleId":"com.example.app"}}}' > "$case_dir/cfg.json"; }
run_iperm(){ local f="$1" bin="$2"; run_ios "$f" PATH="$ROOT/tests/fake-sdk/xcrun-bin:$bin$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"; }

iperm_case ios-perm-privacy
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "photos", "state": "denied" }'
run_iperm "$case_dir/flow.json" ""
begin "setPermission on iOS: photos goes through simctl privacy, denied is revoke"
status_is 0; has xcrun/log "simctl privacy FAKE-UDID revoke photos com.example.app"
verdict

iperm_case ios-perm-asu
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "notifications", "state": "granted" }'
run_iperm "$case_dir/flow.json" "$ROOT/tests/fake-sdk/applesimutils-bin:"
begin "setPermission on iOS: notifications go through applesimutils"
status_is 0; has xcrun/log "applesimutils --byId FAKE-UDID --bundle com.example.app --setPermissions notifications=YES"
verdict

iperm_case ios-perm-no-asu
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "denied" }'
run_iperm "$case_dir/flow.json" ""
begin "setPermission on iOS: without applesimutils, camera stops with a hint"
status_is 1; has out.txt "setPermission: camera on iOS needs applesimutils"; has out.txt "brew install applesimutils"
verdict

iperm_case ios-perm-asu-refuses
printf '%s\n' 'Unable to find simulator' > "$case_dir/xcrun/asu-refuses"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "camera", "state": "granted" }'
run_iperm "$case_dir/flow.json" "$ROOT/tests/fake-sdk/applesimutils-bin:"
begin "setPermission on iOS: a refusal of applesimutils is a failure with its words"
status_is 1; has out.txt "setPermission: applesimutils refused camera=YES for 'com.example.app': Unable to find simulator"
verdict

iperm_case ios-perm-unset
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "location", "state": "unset" }'
run_iperm "$case_dir/flow.json" ""
begin "setPermission on iOS: unset is simctl privacy reset"
status_is 0; has xcrun/log "simctl privacy FAKE-UDID reset location com.example.app"
verdict

iperm_case ios-perm-refused
printf '%s\n' 'Invalid service' > "$case_dir/xcrun/privacy-refuses"
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "motion", "state": "granted" }'
run_iperm "$case_dir/flow.json" ""
begin "setPermission on iOS: a refusal of simctl privacy is a failure with its words"
status_is 1; has out.txt "the simulator refused grant motion for 'com.example.app': Invalid service"
verdict

iperm_case ios-perm-android-name
flow_file "$case_dir/flow.json" '{ "do": "setPermission", "value": "android.permission.health.READ_STEPS", "state": "granted" }'
run_iperm "$case_dir/flow.json" ""
begin "setPermission on iOS: an Android permission name skips the rest of the flow"
status_is 0; has out.txt "skipped: platform: 'android.permission.health.READ_STEPS' is an Android permission name, and this run is iOS"
verdict

# ── turnWheel (#120) ─────────────────────────────────────────────────────────
new_case wheel-missing-key
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "value": -1 }'
expect "check: turnWheel without a wheel number is refused" 1 \
  "step 1 'turnWheel': turnWheel needs a \"wheel\"" check "$case_dir/flow.json"

new_case wheel-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "19", "wheel": 2 }'
expect "check: wheel on a step that does not take it is refused" 1 \
  "step 1 'tapText': step 'tapText' does not take \"wheel\" - only turnWheel does" check "$case_dir/flow.json"

new_case wheel-zero
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "value": -1, "wheel": 0 }'
expect "check: wheel 0 is refused" 1 \
  "\"wheel\" is '0' - it has to be a whole number from 1" check "$case_dir/flow.json"

for r in 0 '"19 Oct"' '""' 151 '"-2.5"' '" -2"' '"2 "'; do
  new_case wheel-rows
  flow_file "$case_dir/flow.json" "{ \"do\": \"turnWheel\", \"wheel\": 1, \"value\": $r }"
  expect "check: turnWheel by $r rows is refused" 1 \
    "turnWheel takes the number of rows to turn the wheel, minus for up, plus for down, not 0 and at most 150" check "$case_dir/flow.json"
done

new_case wheel-var
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "value": "${DAY_BY}", "wheel": "${N}" }'
expect "check: wheel and rows may come from variables" 0 " - 1 steps" env DAY_BY=-2 N=2 "$YUKTI" flow --check "$case_dir/flow.json"

# Android. npick <x1> <value> - a NumberPicker 200 wide, y 1000-1300, and the
# EditText that shows its value; the next row is 100 away from the middle, 1150.
npick(){ printf '<node class="android.widget.NumberPicker" text="" resource-id="" bounds="[%d,1000][%d,1300]" /><node class="android.widget.EditText" text="%s" resource-id="android:id/numberpicker_input" bounds="[%d,1100][%d,1200]" />' \
  "$1" "$(( $1 + 200 ))" "$2" "$1" "$(( $1 + 200 ))"; }
# wheel_screens <value>... - the n-th read shows the n-th value on the middle
# wheel; the two others stay put.
wheel_screens(){ local i=1 v
  for v in "$@"; do screen "$case_dir/adb/dump-$i.xml" "$(npick 0 Nov)" "$(npick 200 "$v")" "$(npick 400 2026)"; i=$((i + 1)); done; }
taps_are(){ local got; got="$(grep '^shell input tap' "$case_dir/adb/log" | sed 's/^shell input tap //' | tr '\n' '|')"
  [ "$got" = "$1" ] || no "taps were '$got', wanted '$1'"; }

dev_case wheel-down
wheel_screens 17 18 19
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 2 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: plus turns the wheel down a row per tap, read after each"
status_is 0; fake_used; has out.txt "turnWheel: wheel 2 turned 2 rows, '17' to '19'"; taps_are "300 1250|300 1250|"
verdict

# A wheel value with a " in it comes single-quoted, like any attribute (#100):
# the wheel reader has to see it to count the row as turned.
dev_case wheel-double-quote
for i in 1 2; do
  screen "$case_dir/adb/dump-$i.xml" "$(npick 0 Nov)" \
    "$(npick 200 "Q$i" | sed "s/text=\"Q$i\"/text='$(( 16 + i ))\"'/")" "$(npick 400 2026)"
done
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 1 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: a value with a double quote is read from its single-quoted attribute"
status_is 0; fake_used; has out.txt "'17\"' to '18\"'"; taps_are "300 1250|"
verdict

dev_case wheel-up
wheel_screens Mar Feb
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": -1 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: minus turns it up"
status_is 0; has out.txt "wheel 2 turned -1 rows, 'Mar' to 'Feb'"; taps_are "300 1050|"
verdict

dev_case wheel-stuck
wheel_screens 17 18 18
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 3 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: a tap that does not move the wheel stops the step and says where"
status_is 1; has out.txt "turnWheel: wheel 2 went from '18' to '18' on row 2 of 3 - it did not move"; taps_are "300 1250|300 1250|"
verdict

dev_case wheel-empty-then-moves
wheel_screens 17 "" 18 19
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 2 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: a read with no value is read again, not counted as a row"
status_is 0; has out.txt "wheel 2 turned 2 rows, '17' to '19'"; taps_are "300 1250|300 1250|"
verdict

dev_case wheel-empty-then-same
wheel_screens 17 "" 17
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 2 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: an empty read between two equal values does not pass as a move"
status_is 1; has out.txt "wheel 2 went from '17' to '17' on row 1 of 2 - it did not move"; taps_are "300 1250|"
verdict

dev_case wheel-empty
wheel_screens 17 "" "" ""
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 2 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: a wheel that keeps showing no value fails by name"
status_is 1; has out.txt "turnWheel: wheel 2 shows no value after row 1 of 2 - nothing to count the rows by"
verdict

dev_case wheel-none
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 1, "value": 1 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: a screen with no wheels says so"
status_is 1; has out.txt "turnWheel: there are no wheels on the screen"
verdict

dev_case wheel-absent
screen "$case_dir/adb/dump-1.xml" "$(npick 0 Nov)"
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 1 }'
run_flow "$case_dir/flow.json"
begin "turnWheel: a wheel number past the last one says how many there are"
status_is 1; has out.txt "turnWheel: no wheel 2 on the screen, there is 1"
verdict

# iOS. iwheel <x> <width> <value> - one wheel of a date picker as idb lists it
# on an iOS 26.5 simulator: a slider with the PickerElement trait, no id, no
# label, its value the row number, y 54-345 (middle 199).
iwheel(){ printf '{"type":"Slider","role_description":"slider","AXUniqueId":null,"AXLabel":null,"AXValue":%s,"traits":["Selected","Adjustable","PickerElement","Scrollable"],"frame":{"x":%s,"y":54.83,"width":%s,"height":291}}' "$3" "$1" "$2"; }
islider='{"type":"Slider","role_description":"slider","AXUniqueId":"volume","AXLabel":"Volume","AXValue":"50%","traits":["Adjustable"],"frame":{"x":20,"y":10,"width":300,"height":30}}'
iwheel_screens(){ local i=1 v
  for v in "$@"; do tree "$case_dir/idb/desc-$i.json" "$islider" "$(iwheel 260 75 2025)" "$(iwheel 68 133 5002)" "$(iwheel 206 49 "$v")"; i=$((i + 1)); done; }
itaps_are(){ local got; got="$(grep '^ui tap' "$case_dir/idb/log" | sed 's/^ui tap --udid FAKE-UDID //' | tr '\n' '|')"
  [ "$got" = "$1" ] || no "taps were '$got', wanted '$1'"; }

ios_case ios-wheel-up
iwheel_screens 4993 4992 4991
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": -2 }'
run_ios "$case_dir/flow.json"
begin "turnWheel on iOS: wheels left to right by their trait, a plain slider is not one; the row number moves by one per tap"
status_is 0; has out.txt "turnWheel: wheel 2 turned -2 rows, '4993' to '4991'"; itaps_are "230 167|230 167|"
verdict

ios_case ios-wheel-refused
iwheel_screens 4993 4993
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": 1 }'
run_ios "$case_dir/flow.json"
begin "turnWheel on iOS: a row the picker refuses is a failure by name"
status_is 1; has out.txt "wheel 2 went from '4993' to '4993' on row 1 of 1 - it did not move"
verdict

ios_case ios-wheel-no-value
iwheel_screens 4993 null null null
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": -1 }'
run_ios "$case_dir/flow.json"
begin "turnWheel on iOS: a wheel with no value is not counted as a row"
status_is 1; has out.txt "wheel 2 shows no value after row 1 of 1"
verdict

ios_case ios-wheel-text
iwheel_screens '"October"' '"September"'
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": -1 }'
run_ios "$case_dir/flow.json"
begin "turnWheel on iOS: a wheel that reports text has to change it"
status_is 0; has out.txt "wheel 2 turned -1 rows, 'October' to 'September'"
verdict

ios_case ios-wheel-jump
iwheel_screens 4992 4991 4993
flow_file "$case_dir/flow.json" '{ "do": "turnWheel", "wheel": 2, "value": -2 }'
run_ios "$case_dir/flow.json"
begin "turnWheel on iOS: a wheel that jumps back is not counted as a row"
status_is 1; has out.txt "wheel 2 went from '4991' to '4993' on row 2 of 2 - not the next row: the picker did not take that row"
verdict

# A box against another element (#127): above, below, leftOf, rightOf, apart.
# bnode <id> <x1> <y1> <x2> <y2> - a control with these corners.
bnode(){ printf '<node index="0" text="" resource-id="com.example:id/%s" class="android.view.ViewGroup" package="com.example" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[%d,%d][%d,%d]" />' \
  "$1" "$2" "$3" "$4" "$5"; }

dev_case box-numeric
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card-b 0 500 1080 600)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "minHeight": 100, "maxWidth": "100%" } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId: the size and the edges, as before"
status_is 0; fake_used; has out.txt "assert box: id 'card-b' is 1080x100 at [0,500][1080,600]"
verdict

# The second dump holds the two cards swapped: a step that read the screen twice
# would compare two frames and go red.
dev_case box-below
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card-a 0 300 1080 400)" "$(bnode card-b 0 500 1080 600)")"
screen "$case_dir/adb/dump-2.xml" "$(sroot "$(bnode card-a 0 500 1080 600)" "$(bnode card-b 0 300 1080 400)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "below": "card-a", "apart": "card-a" } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId below and apart: B under A, both boxes from one read"
status_is 0; fake_used; value_is adb/dumps 1
has out.txt "assert box: id 'card-b' is 1080x100 at [0,500][1080,600], apart 'card-a', below 'card-a'"
verdict

dev_case box-below-swapped
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card-a 0 300 1080 400)" "$(bnode card-b 0 500 1080 600)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-a", "box": { "below": "card-b" } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId below: with A and B swapped the same check is red and prints both boxes"
status_is 1
has out.txt "assert FAILED: id 'card-a' is 1080x100 at [0,300][1080,400] - expected below 'card-b' (1080x100 at [0,500][1080,600])"
verdict

dev_case box-left-right
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode left 0 500 500 600)" "$(bnode right 500 500 1080 600)" "$(bnode bar 0 2200 1080 2400)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "left", "box": { "leftOf": "right", "above": "bar" } }' \
  '{ "do": "assertBoxId", "value": "right", "box": { "rightOf": "left", "apart": "left" } }' \
  '{ "do": "assertBoxId", "value": "bar", "box": { "below": "right" } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId leftOf, rightOf, above: edges that touch keep the relation"
status_is 0
has out.txt "assert box: id 'left' is 500x100 at [0,500][500,600], above 'bar', leftOf 'right'"
has out.txt "assert box: id 'right' is 580x100 at [500,500][1080,600], apart 'left', rightOf 'left'"
has out.txt "assert box: id 'bar' is 1080x200 at [0,2200][1080,2400], below 'right'"
verdict

dev_case box-apart-overlap
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode a 0 500 600 600)" "$(bnode b 500 550 1080 650)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "b", "box": { "apart": "a" } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId apart: two boxes that overlap are red"
status_is 1; has out.txt "assert FAILED: id 'b' is 580x100 at [500,550][1080,650] - expected apart 'a' (600x100 at [0,500][600,600])"
verdict

dev_case box-mixed
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card-a 0 300 1080 400)" "$(bnode card-b 0 500 1080 600)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-a", "box": { "below": "card-b", "minHeight": 200 } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId: a relation and a size that both miss are named in one line"
status_is 1
has out.txt "expected below 'card-b' (1080x100 at [0,500][1080,600]), height at least 200 (is 100)"
verdict

dev_case box-other-missing
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card-b 0 500 1080 600)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "below": "card-a" } }'
run_flow "$case_dir/flow.json"
begin "assertBoxId below: the other element not on the screen is a failure that names it"
status_is 1; has out.txt "assert FAILED: no element with id 'card-a' to compare id 'card-b' with"
verdict

dev_case box-cli
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card-a 0 300 1080 400)" "$(bnode card-b 0 500 1080 600)")"
env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" assert-box card-b id below=card-a > "$case_dir/out" 2>&1
run_status=$?; sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"
begin "assert-box by hand: below=<id>"
status_is 0; has out.txt "below 'card-a'"
verdict

new_case box-rel-check
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "below": "card-a", "minHeight": "48dp" } }' \
  '{ "do": "assertBox", "value": "Reconnect", "box": { "above": "tab-bar" } }'
expect "check: a relation by id builds, alone and next to a number" 0 " - 2 steps" check "$case_dir/flow.json"

new_case box-rel-not-string
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "below": 5 } }'
expect "check: a relation that is not an id is refused" 1 \
  "'below' names another element by its id, for instance {\"below\": \"card-a\"}" check "$case_dir/flow.json"

new_case box-rel-self
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-a", "box": { "apart": "card-a" } }'
expect "check: a box measured against itself is refused" 1 \
  "'apart' names the element the step measures, 'card-a' - name the other element" check "$case_dir/flow.json"

new_case box-rel-unknown
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "belwo": "card-a" } }'
expect "check: a misspelt relation is refused with the list of both kinds" 1 \
  "'belwo' is not a constraint - this version knows maxHeight, maxWidth, maxX, maxY, minHeight, minWidth, minX, minY, and above, apart, below, leftOf, rightOf with an id" check "$case_dir/flow.json"

# The same on iOS: frames in points, the other element by AXUniqueId.
ios_case ios-box-below
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate card-a Button 200 "" '["Button"]')" "$(istate card-b Button 300 "" '["Button"]')"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "below": "card-a", "apart": "card-a" } }' \
  '{ "do": "assertBoxId", "value": "card-a", "box": { "below": "card-b" } }'
run_ios "$case_dir/flow.json"
begin "assertBoxId below on iOS: B under A passes, swapped is red with both boxes"
status_is 1
has out.txt "assert box: id 'card-b' is 360x44 at [20,300][380,344], apart 'card-a', below 'card-a'"
has out.txt "assert FAILED: id 'card-a' is 360x44 at [20,200][380,244] - expected below 'card-b' (360x44 at [20,300][380,344])"
verdict

# One read on iOS too: the second tree holds the cards swapped.
ios_case ios-box-one-read
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate card-a Button 200 "" '["Button"]')" "$(istate card-b Button 300 "" '["Button"]')"
tree "$case_dir/idb/desc-2.json" "$IAPP" "$(istate card-a Button 300 "" '["Button"]')" "$(istate card-b Button 200 "" '["Button"]')"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card-b", "box": { "below": "card-a", "apart": "card-a" } }'
run_ios "$case_dir/flow.json"
begin "assertBoxId below on iOS: both boxes from one read of the tree"
status_is 0; ireads_are 1; has out.txt "below 'card-a'"
verdict

# waitForNotText and waitForNotId (#104): the wait the other way. A sheet that
# closes on the second read passes there; one still open at the timeout fails
# with where it is; a screen that stops being readable is never taken for gone.
SHEET="$(node TextView sheet 'Saving draft')"
dev_case gone-second-read
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SHEET"
screen "$case_dir/adb/dump-2.xml" "$ROOT_NODE" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet", "timeout": 5 }'
run_flow "$case_dir/flow.json"
begin "waitForNotId: passes on the read that finds the element gone"
status_is 0; reads_are 2; has out.txt "waitForNot id: 'sheet' gone from the screen after"
verdict

dev_case gone-already
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet" }'
run_flow "$case_dir/flow.json"
begin "waitForNotId: an element already gone passes on the first read"
status_is 0; reads_are 1; has out.txt "'sheet' gone from the screen after "
verdict

dev_case gone-timeout
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SHEET"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForNotId: still there at the timeout is a failure that says where"
status_is 1; has out.txt "waitForNot id FAILED: 'sheet' still on the screen at "; has out.txt " after 1s"
red_is failure StepFailed 1 0
verdict

dev_case gone-unreadable
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SHEET"
printf 'not a dump' > "$case_dir/adb/dump-2.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForNotId: a screen that stops being readable is not a disappearance"
status_is 1; has out.txt "waitForNot id FAILED after 1s waiting for 'sheet' to go: cannot read the screen"
lacks out.txt "gone from the screen"; red_is error DeviceError 0 1
verdict

# A zero-size element is not on the screen, as assertNotId counts it.
dev_case gone-zero-size
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForNotId: an element at zero size counts as gone, as for assertNotId"
status_is 0; reads_are 1; has out.txt "'btn' gone from the screen after "
verdict

new_case gone-in
flow_file "$case_dir/flow.json" '{ "do": "waitForNotText", "value": "Saving", "in": "sheet" }'
expect "check: waitForNotText does not take \"in\" yet" 1 \
  "step 'waitForNotText' does not take \"in\" - only " check "$case_dir/flow.json"

dev_case gone-text-contains
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SHEET"
screen "$case_dir/adb/dump-2.xml" "$ROOT_NODE" "$(node TextView title 'Draft saved')"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotText", "value": "Saving", "match": "contains", "timeout": 5 }'
run_flow "$case_dir/flow.json"
begin "waitForNotText contains: waits for the text to leave, matching as assertNotText"
status_is 0; reads_are 2; has out.txt "waitForNot (contains match): 'Saving' gone from the screen after"
verdict

dev_case gone-text-exact
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SHEET"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotText", "value": "Saving", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForNotText exact: a label that only holds the text does not count as it"
status_is 0; reads_are 1; has out.txt "'Saving' gone from the screen after "
verdict

dev_case gone-id-match
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet", "match": "contains" }'
run_flow "$case_dir/flow.json"
begin "waitForNotId: a match is refused, it matches the id exactly"
status_is 1; has out.txt "does not take a \"match\" - only assertText, assertNotText, assertCount, waitFor and waitForNotText do"
verdict

dev_case gone-cli
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SHEET"
screen "$case_dir/adb/dump-2.xml" "$ROOT_NODE"
env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" wait-for-not-id sheet 5 > "$case_dir/out" 2>&1
run_status=$?; sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"
begin "wait-for-not-id by hand"
status_is 0; has out.txt "'sheet' gone from the screen after"
verdict

dev_case gone-cli-text
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SHEET"
screen "$case_dir/adb/dump-2.xml" "$ROOT_NODE"
env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" wait-for-not Saving 5 contains > "$case_dir/out" 2>&1
run_status=$?; sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"
begin "wait-for-not by hand, contains"
status_is 0; has out.txt "waitForNot (contains match): 'Saving' gone from the screen after"
verdict

ios_case ios-gone
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(ibutton sheet)"
tree "$case_dir/idb/desc-2.json" "$IAPP"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet", "timeout": 5 }'
run_ios "$case_dir/flow.json"
begin "waitForNotId on iOS: passes on the read that finds the element gone"
status_is 0; ireads_are 2; has out.txt "'sheet' gone from the screen after"
verdict

ios_case ios-gone-unreadable
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(ibutton sheet)"
printf 'not a tree' > "$case_dir/idb/desc-2.json"
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForNotId on iOS: an unreadable tree is not a disappearance"
status_is 1; has out.txt "waitForNot id FAILED after 1s waiting for 'sheet' to go:"; lacks out.txt "gone from the screen"
verdict

new_case gone-check
flow_file "$case_dir/flow.json" '{ "do": "waitForNotText", "value": "Saving", "match": "contains", "timeout": 3 }' '{ "do": "waitForNotId", "value": "sheet" }'
expect "check: waitForNotText and waitForNotId are steps the builder knows" 0 "" check "$case_dir/flow.json"

# ── swipeId / swipeText: a swipe on an element (#82) ────────────────────────
new_case swipe-no-direction
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1" }'
expect "check: swipeId without a direction is refused" 1 \
  "step 1 'swipeId' needs a \"direction\" - up, down, left or right, where the finger goes" check "$case_dir/flow.json"

new_case swipe-bad-direction
flow_file "$case_dir/flow.json" '{ "do": "swipeText", "value": "Invoice", "direction": "sideways" }'
expect "check: swipeText with a direction that is not one is refused" 1 \
  "step 1 'swipeText': 'sideways' is not a direction - use up, down, left or right" check "$case_dir/flow.json"

new_case swipe-direction-elsewhere
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "row-1", "direction": "left" }'
expect "check: direction on a step that does not take it names the three that do" 1 \
  "does not take a \"direction\" - only scrollToText, swipeId and swipeText do" check "$case_dir/flow.json"

new_case swipe-check-ok
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }' '{ "do": "swipeText", "value": "${ROW}", "direction": "up" }'
expect "check: swipeId and swipeText with a direction build" 0 " - 2 steps" env ROW=Invoice "$YUKTI" flow --check "$case_dir/flow.json"

# A row 1080x160 at y 400: the centre is 540,480, 60% of the width is 648.
dev_case swipe-left
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeId left: the finger goes right to left across the row, centred on it, and stays inside"
status_is 0; fake_used; has adb/log "shell input swipe 864 480 216 480 486"
has out.txt "swiped id 'row-1' left, 864,480 to 216,480 (60% of 1080x160)"
verdict

dev_case swipe-right-text
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560 | sed 's/ text=""/ text="Invoice"/')")"
flow_file "$case_dir/flow.json" '{ "do": "swipeText", "value": "Invoice", "direction": "right" }'
run_flow "$case_dir/flow.json"
begin "swipeText right: found by its text, the finger goes left to right"
status_is 0; has adb/log "shell input swipe 216 480 864 480 486"
verdict

# Up and down take the height: 200 high, 60% is 120, and a short stroke is held to 300 ms.
dev_case swipe-up
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card 100 400 300 600)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "card", "direction": "up" }'
run_flow "$case_dir/flow.json"
begin "swipeId up: a share of the height, at least 300 ms"
status_is 0; has adb/log "shell input swipe 200 560 200 440 300"
verdict

dev_case swipe-share
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_flow "$case_dir/flow.json" YUKTI_SWIPE_SHARE=30
begin "swipeId: YUKTI_SWIPE_SHARE shortens the stroke"
status_is 0; has adb/log "shell input swipe 702 480 378 480 300"
verdict

dev_case swipe-share-bad
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_flow "$case_dir/flow.json" YUKTI_SWIPE_SHARE=95
begin "swipeId: a share above 90 would start on the element's edge and is refused"
status_is 1; has out.txt "YUKTI_SWIPE_SHARE must be a whole share of the element from 1 to 90, is '95'"; lacks adb/log "input swipe"
verdict

for v in 0 060 6x; do
  dev_case swipe-share-word
  screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560)")"
  flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
  run_flow "$case_dir/flow.json" YUKTI_SWIPE_SHARE=$v
  begin "swipeId: YUKTI_SWIPE_SHARE=$v is refused"
  status_is 1; has out.txt "with no leading zero, is '$v'"; lacks adb/log "input swipe"
  verdict
done

dev_case swipe-miss-id
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-9", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeId: a missing element in the words of tapId, nothing swiped"
status_is 1; has out.txt "no element with id 'row-9'"; lacks adb/log "input swipe"
verdict

dev_case swipe-miss-text
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560 | sed 's/ text=""/ text="Invoice"/')")"
flow_file "$case_dir/flow.json" '{ "do": "swipeText", "value": "Receipt", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeText: a missing element in the words of tapText, nothing swiped"
status_is 1; has out.txt "no element matching 'Receipt'"; lacks adb/log "input swipe"
verdict

dev_case swipe-tiny
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode dot 500 500 503 503)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "dot", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeId: an element too small for a stroke fails instead of tapping it"
status_is 1; has out.txt "swipeId: 'dot' is 3x3 on the screen - 60% of it is a stroke of 0, the app would take less than 48 for a tap"; lacks adb/log "input swipe"
verdict

# 70 wide: 60% is 42 pixels, under the touch slop with a margin.
dev_case swipe-narrow
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode chip 500 500 570 600)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "chip", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeId: a stroke the app would read as a tap fails the step"
status_is 1; has out.txt "60% of it is a stroke of 42, the app would take less than 48 for a tap"; lacks adb/log "input swipe"
verdict

dev_case swipe-down
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode card 100 400 300 600)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "card", "direction": "down" }'
run_flow "$case_dir/flow.json"
begin "swipeId down: top to bottom, a share of the height"
status_is 0; has adb/log "shell input swipe 200 440 200 560 300"; has out.txt "swipe id 'card' down"
verdict

# A row 2000 wide on a 1080 screen, its centre on the screen: the stroke is
# measured on the part that can be touched, the same as for a 1080 row.
dev_case swipe-wider-than-screen
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode strip 0 400 2000 560)")"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "strip", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeId: an element past the edge of the screen is swiped on its part on the screen"
status_is 0; has adb/log "shell input swipe 864 480 216 480 486"
verdict

dev_case swipe-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeId: a screen that cannot be read stops the step, nothing swiped"
status_is 1; fake_used; lacks out.txt "no element with id"; lacks adb/log "input swipe"
verdict

new_case swipe-cli-no-direction
expect "swipe-id by hand without a direction is refused" 1 \
  "swipeId needs a direction - up, down, left or right, where the finger goes" \
  env ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 FAKE_ADB_DIR="$case_dir" TMPDIR="$case_dir" "$YUKTI" swipe-id row-1

dev_case swipe-keyboard
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode row-1 0 400 1080 560)")"
: > "$case_dir/adb/keyboard"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_flow "$case_dir/flow.json"
begin "swipeId: a keyboard is closed before the row is looked up"
status_is 0; has adb/log "shell input keyevent 4"; lacks adb/log "keyevent 111"; has adb/log "shell input swipe 864 480 216 480 486"
k="$(grep -n 'keyevent 4$' "$case_dir/adb/log" | head -1 | cut -d: -f1)"
r="$(grep -n 'uiautomator dump' "$case_dir/adb/log" | tail -1 | cut -d: -f1)"
[ -n "$k" ] && [ -n "$r" ] && [ "$k" -lt "$r" ] || no "the row was read (line $r) before the keyboard was closed (line $k)"
verdict

# iOS: istate is 360x44 at 20,<y>: at y 200 the centre is 200,222, 60% of the width is 216.
ios_case ios-swipe-left
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate row-1 Button 200 "" '["Button"]')"
ipoint row-1 20 200 360 44
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_ios "$case_dir/flow.json"
begin "swipeId on iOS: idb swipe inside the frame, with an explicit duration"
status_is 0; has idb/log "ui swipe --udid FAKE-UDID --duration 1.44 308 222 92 222"; lacks out.txt "covered"
verdict

ios_case ios-swipe-covered
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate row-1 Button 200 "" '["Button"]')"
ipoint tab-bar 0 200 402 60
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_ios "$case_dir/flow.json"
begin "swipeId on iOS: an element over the start point fails the step by name, nothing swiped"
status_is 1; has out.txt "'row-1' at 308,222 is covered by tab-bar - not swiped"; lacks idb/log "ui swipe"
verdict

# 44 high: 60% is 26 points, over the 20 of iOS; the finger is held to 0.3 s.
ios_case ios-swipe-up
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate row-1 Button 200 "" '["Button"]')"
ipoint row-1 20 200 360 44
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "up" }'
run_ios "$case_dir/flow.json"
begin "swipeId up on iOS: a share of the height, at least 0.3 s"
status_is 0; has idb/log "ui swipe --udid FAKE-UDID --duration 0.30 200 235 200 209"
verdict

ios_case ios-swipe-unknown
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate row-1 Button 200 "" '["Button"]')"
flow_file "$case_dir/flow.json" '{ "do": "swipeId", "value": "row-1", "direction": "left" }'
run_ios "$case_dir/flow.json"
begin "swipeId on iOS: no answer from describe-point swipes as before, with a warning"
status_is 0; has out.txt "could not read what is under 'row-1' at 308,222 - swiping as before"; has idb/log "ui swipe"
verdict

# ── tapId "at": a point inside the element (#129) ────────────────────────────
new_case at-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Volume", "at": { "x": "50%" } }'
expect "check: at on a step other than tapId is refused" 1 \
  "step 1 'tapText': step 'tapText' does not take \"at\" - only tapId does" check "$case_dir/flow.json"

for a in '{ "x": 50 }' '{ "x": "50" }' '{ "x": "50px" }' '{ "x": "12.5%" }' '{ "x": "-5%" }' '{ "x": "\u00b2%" }'; do
  new_case at-not-share
  flow_file "$case_dir/flow.json" "{ \"do\": \"tapId\", \"value\": \"track\", \"at\": $a }"
  expect "check: at $a is refused - a whole share written with %" 1 \
    "it has to be a whole share of the element written with %, from \"0%\" to \"100%\"" check "$case_dir/flow.json"
done

new_case at-over
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "y": "101%" } }'
expect "check: a share over 100% is refused" 1 "a point inside the element is at most \"100%\"" check "$case_dir/flow.json"

new_case at-key
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "left": "50%" } }'
expect "check: a part of a point other than x and y is refused" 1 "'left' is not a part of a point - \"at\" takes x and y" check "$case_dir/flow.json"

for a in '{}' '"50%"' '[50]'; do
  new_case at-shape
  flow_file "$case_dir/flow.json" "{ \"do\": \"tapId\", \"value\": \"track\", \"at\": $a }"
  expect "check: at $a is refused - it is an object with x or y" 1 "\"at\" is a point inside the element as shares of its box" check "$case_dir/flow.json"
done

new_case at-var
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "${STOP}" } }'
expect "check: a share may come from a variable" 0 " - 1 steps" env STOP=50% "$YUKTI" flow --check "$case_dir/flow.json"

# A track 1000x80 at 40,1000.
dev_case at-middle
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "50%" } }' \
  '{ "do": "tapId", "value": "track", "at": { "x": "25%", "y": "25%" } }' \
  '{ "do": "tapId", "value": "track", "at": { "x": "0%" } }' \
  '{ "do": "tapId", "value": "track", "at": { "x": "100%" } }' \
  '{ "do": "tapId", "value": "track", "at": { "x": "07%" } }'
run_flow "$case_dir/flow.json"
begin "tapId at: shares of the box from its left and top edge, the other axis at the centre, 100% the last pixel inside"
status_is 0; fake_used; taps_are "540 1040|290 1020|40 1040|1039 1040|110 1040|"
has out.txt "tap id 'track' at 50% x 50% of 1000x80: 540,1040"
verdict

dev_case at-plain
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track" }'
run_flow "$case_dir/flow.json"
begin "tapId without at taps the centre, as before"
status_is 0; taps_are "540 1040|"; lacks out.txt "% x "
verdict

# 2000 wide on a 1080 screen: its centre is on the screen, 90% of it is not.
dev_case at-off-screen
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 0 1000 2000 1080)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "90%" } }'
run_flow "$case_dir/flow.json"
begin "tapId at: a point off the screen fails the step, nothing tapped"
status_is 1; has out.txt "'track' at 90% x 50% is 1800,1040, off the screen [0,0][1080,2400] - not tapped"; taps_are ""
verdict

dev_case at-miss
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "slider", "at": { "x": "50%" } }'
run_flow "$case_dir/flow.json"
begin "tapId at: a missing element in the words of tapId"
status_is 1; has out.txt "no element with id 'slider'"; taps_are ""
verdict

dev_case at-cli
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
expect "tap-id by hand with a share taps that point" 0 "tap id 'track' at 75% x 50% of 1000x80: 790,1040" \
  env ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" tap-id track 75%

dev_case at-cli-bad
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
for a in half 50; do
  expect "tap-id by hand with '$a' is refused - a share is written with %" 1 "tapId: a point is a whole share of the element written with %, for instance 50%, got '$a'" \
    env ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" tap-id track "$a"
done
expect "tap-id by hand with a share over 100 is refused" 1 "tapId: a point is a whole share of the element from 0 to 100, got '150'" \
  env ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" tap-id track 150%

dev_case at-cli-y
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
expect "tap-id by hand with both shares" 0 "tap id 'track' at 75% x 25% of 1000x80: 790,1020" \
  env ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" tap-id track 75% 25%

dev_case at-y-only
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "y": "0%" } }' '{ "do": "tapId", "value": "track", "at": { "y": "100%" } }'
run_flow "$case_dir/flow.json"
begin "tapId at: y alone keeps x at the centre, 100% is the last row inside"
status_is 0; taps_are "540 1000|540 1079|"
verdict

# A skipped step carries the point in its record like any other field: the
# step after it reads its own fields, not the leftovers of the skipped one.
dev_case at-skipped
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "0%" }, "when": { "visibleId": "nothing" } }' '{ "do": "tapId", "value": "track" }'
run_flow "$case_dir/flow.json"
begin "tapId at: a step skipped by its condition taps nothing, the next one its own centre"
status_is 0; taps_are "540 1040|"; has out.txt "skipped"
verdict

# iOS: istate is 360x44 at 20,200 - 25% of the width is x 110, the centre y 222.
ios_case ios-at
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate track Slider 200 "" '[]')"
ipoint track 20 200 360 44
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "25%" } }'
run_ios "$case_dir/flow.json"
begin "tapId at on iOS: the point inside the frame, in points"
status_is 0; has idb/log "ui tap --udid FAKE-UDID 110 222"
verdict

ios_case ios-at-thumb
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate track Slider 200 "" '[]')"
ipoint thumb 95 200 30 44
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "25%" } }'
run_ios "$case_dir/flow.json"
begin "tapId at on iOS: a thumb with its own id over the point fails as covered, nothing tapped"
status_is 1; has out.txt "'track' at 110,222 is covered by thumb"; lacks idb/log "ui tap"; lacks out.txt "tap id 'track' at 25%"
verdict

# ── a place on the screen, and a swipe between two (#48) ────────────────────
# A point is pixels, as recorded, or a whole share of the screen ("50%"). A
# share is of the screen the run is on and is never rescaled; pixels still are.
# The fake Android screen is 1080x2400, the recording basis 402x874.
new_case xy-share-ok
flow_file "$case_dir/flow.json" '{ "do": "tap", "x": "50%", "y": "80%" }' '{ "do": "clearText", "x": 201, "y": "08%" }' \
  '{ "do": "swipe", "x": "50%", "y": 300, "toX": "50%", "toY": "100%" }'
expect "check: shares of the screen and pixels both build" 0 " - 3 steps" check "$case_dir/flow.json"

new_case xy-share-over
flow_file "$case_dir/flow.json" '{ "do": "tap", "x": "150%", "y": "80%" }'
expect "check: a share over 100% is refused" 1 \
  "step 1 'tap': \"x\" is '150%' - a share of the screen cannot be more than 100%" check "$case_dir/flow.json"

new_case xy-not-a-number
flow_file "$case_dir/flow.json" '{ "do": "tap", "x": "50%", "y": "abc" }'
expect "check: a coordinate that is not a number is refused" 1 \
  "step 1 'tap': \"y\" is 'abc' - it has to be a whole number of pixels (200) or a whole share of the screen (\"50%\")" check "$case_dir/flow.json"

new_case xy-fraction
flow_file "$case_dir/flow.json" '{ "do": "clearText", "x": 12.5, "y": 300 }'
expect "check: a fraction of a pixel is refused" 1 \
  "step 1 'clearText': \"x\" is '12.5' - it has to be a whole number of pixels" check "$case_dir/flow.json"

new_case xy-missing
flow_file "$case_dir/flow.json" '{ "do": "tap", "x": 200 }'
expect "check: a tap without y is refused before the run" 1 \
  "step 1 'tap': tap needs \"y\" - \"x\", \"y\", each pixels (200) or a share of the screen (\"50%\")" check "$case_dir/flow.json"

new_case swipe-missing-to
flow_file "$case_dir/flow.json" '{ "do": "swipe", "x": "50%", "y": "80%", "toX": "50%" }'
expect "check: a swipe without its end is refused" 1 \
  "step 1 'swipe': swipe needs \"toY\" - \"x\", \"y\", \"toX\", \"toY\"" check "$case_dir/flow.json"

new_case swipe-same-point
flow_file "$case_dir/flow.json" '{ "do": "swipe", "x": "50%", "y": "80%", "toX": "50%", "toY": "080%" }'
expect "check: a swipe that ends where it starts is refused" 1 \
  "step 1 'swipe': the swipe starts and ends at 50%,80% - that is a press, not a swipe" check "$case_dir/flow.json"

new_case to-on-tap
flow_file "$case_dir/flow.json" '{ "do": "tap", "x": "50%", "y": "80%", "toY": "20%" }'
expect "check: toY on a tap is refused" 1 \
  "step 1 'tap': step 'tap' does not take \"toY\" - only swipe does" check "$case_dir/flow.json"

dev_case xy-android-tap
flow_file "$case_dir/flow.json" '{ "do": "tap", "x": "50%", "y": "80%" }' '{ "do": "tap", "x": 201, "y": 437 }' \
  '{ "do": "tap", "x": "100%", "y": "0%" }' '{ "do": "tap", "x": "50%", "y": 300 }'
run_flow "$case_dir/flow.json"
begin "tap on Android: a share is of the screen and not scaled, pixels are scaled as before"
status_is 0; fake_used
has adb/log "shell input tap 540 1920"; has out.txt "point 50%,80% -> 540,1920 (screen 1080x2400)"
has adb/log "shell input tap 540 1200"; has out.txt "scaled 201,437 -> 540,1200"
has adb/log "shell input tap 1079 0"
has adb/log "shell input tap 540 823"; has out.txt "point 50%,300 -> 540,823 (pixels recorded 402x874, screen 1080x2400)"
verdict

dev_case swipe-android
flow_file "$case_dir/flow.json" '{ "do": "swipe", "x": "50%", "y": "80%", "toX": "50%", "toY": "20%" }' \
  '{ "do": "swipe", "x": "50%", "y": "50%", "toX": "50%", "toY": "52%" }'
run_flow "$case_dir/flow.json"
begin "swipe on Android: between two shares of the screen, with a duration, never under 300 ms"
status_is 0
has adb/log "shell input swipe 540 1920 540 480 1080"; has out.txt "swipe 540,1920 -> 540,480 in 1080 ms"
has adb/log "shell input swipe 540 1200 540 1248 300"
verdict

dev_case swipe-android-keyboard
: > "$case_dir/adb/keyboard"
flow_file "$case_dir/flow.json" '{ "do": "swipe", "x": "50%", "y": "30%", "toX": "50%", "toY": "70%" }'
run_flow "$case_dir/flow.json"
begin "swipe on Android: a keyboard that is up is closed first, as for scroll"
status_is 0; file_absent adb/keyboard
has out.txt "swipe, before swiping: keyboard closed"; has adb/log "shell input swipe 540 720 540 1680 720"
verdict

ios_case xy-ios
printf '393 852' > "$case_dir/idb/screen"
tree "$case_dir/idb/desc-1.json" "$IAPP"
flow_file "$case_dir/flow.json" '{ "do": "tap", "x": "50%", "y": "80%" }' \
  '{ "do": "swipe", "x": "50%", "y": "80%", "toX": "50%", "toY": "20%" }' \
  '{ "do": "swipe", "x": "50%", "y": "50%", "toX": "50%", "toY": "52%" }'
run_ios "$case_dir/flow.json"
begin "tap and swipe on iOS: shares of the screen in points, the swipe with a duration"
status_is 0
has idb/log "ui tap --udid FAKE-UDID 196 681"
has idb/log "ui swipe --udid FAKE-UDID --duration 3.41 196 681 196 170"
has idb/log "ui swipe --udid FAKE-UDID --duration 0.30 196 426 196 443"
has out.txt "swipe 196,681 -> 196,170 in 3.41 s"; lacks out.txt "screen size unavailable"
verdict

# The command line: pixels are the device's own, as they always were for
# `yukti tap`; a share is worked out from the screen.
run_cli(){ env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
    FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" "$@" >> "$case_dir/out" 2>&1
  run_status=$?
  sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"; }
dev_case xy-cli
begin "command line: tap and swipe take shares of the screen, tap keeps raw pixels"
run_cli tap 50% 80%; status_is 0; run_cli tap 300 400; status_is 0; run_cli swipe 10% 50% 90% 50%; status_is 0
has adb/log "shell input tap 540 1920"; has adb/log "shell input tap 300 400"
has adb/log "shell input swipe 108 1200 972 1200 648"
verdict
dev_case xy-cli-bad
run_cli tap 150% 10
begin "command line: a share over 100% or too many digits is refused with the builder's words"
status_is 1; has out.txt "tap: \"x\" is '150%' - a share of the screen cannot be more than 100%"
lacks adb/log "input tap"
run_cli tap 9223372036854775808% 1
status_is 1; has out.txt "tap: \"x\" is '9223372036854775808%' - more than any screen has"
lacks adb/log "input tap"
verdict

new_case scroll-point
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down", "x": "50%", "y": "20%" }'
expect "check: a point on scroll is refused, pointing to swipe" 1 \
  "step 1 'scroll': scroll takes no point (\"x\") - for a swipe between two points use swipe" check "$case_dir/flow.json"

# Pixel ends of a swipe are scaled as a tap's are; two forms that land on one
# pixel are refused when the run works the points out.
dev_case swipe-android-pixels
flow_file "$case_dir/flow.json" '{ "do": "swipe", "x": 201, "y": 600, "toX": 201, "toY": 200 }' \
  '{ "do": "swipe", "x": "50%", "y": "50%", "toX": 201, "toY": 437 }'
run_flow "$case_dir/flow.json"
begin "swipe on Android: pixel ends are scaled; a share and a pixel on one point are refused"
status_is 1
has adb/log "shell input swipe 540 1647 540 549 823"
has out.txt "swipe: from 540,1200 to 540,1200 does not move"
count_is adb/log "input swipe" 1
verdict

# ── one of several matches: "index" (#46) ────────────────────────────────────
# xnode <id> <text> <x1> <y1> <x2> <y2> - a control with a label and an id.
xnode(){ printf '<node index="0" text="%s" resource-id="%s" class="android.widget.Button" package="com.example" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[%d,%d][%d,%d]" />' \
  "$2" "${1:+com.example:id/$1}" "$3" "$4" "$5" "$6"; }
atap_is(){ grep -qx "shell input tap $1" "$case_dir/adb/log" || no "no tap at $1 - the device was asked: $(grep '^shell input tap' "$case_dir/adb/log" | tr '\n' '|')"; }
no_atap(){ ! grep -q '^shell input tap' "$case_dir/adb/log" || no "a tap went to the device"; }
# Three equal buttons, listed in the dump in an order that is not the screen's:
# the lower one first, then the right one of the top row (a little lower than
# its neighbour, still the same row), then the left one.
X_GRID="$(xnode "" Continue 100 900 500 1000)$(xnode "" Continue 600 310 1000 410)$(xnode "" Continue 100 300 500 400)"

dev_case idx-tap-text
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_GRID")"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Continue", "index": 1 }' '{ "do": "tapText", "value": "Continue", "index": 2 }' \
  '{ "do": "tapText", "value": "Continue", "index": 0 }'
run_flow "$case_dir/flow.json"
begin "index: tapText counts top to bottom, then left to right, not in dump order"
status_is 0; fake_used; atap_is "800 360"; atap_is "300 950"; atap_is "300 350"
has out.txt "tap 'Continue' index 1"
verdict

dev_case idx-out-of-range
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_GRID")"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Continue", "index": 3 }'
run_flow "$case_dir/flow.json"
begin "index: past the last match the step stops, says how many matched and taps nothing"
status_is 1; no_atap
has out.txt "index 3 is out of range: 3 elements match 'Continue' as closely as the best match on the screen (the index counts from 0, top to bottom, then left to right)"
has res/flow.xml "index 3 is out of range: 3 elements match"
verdict

# Rows: centres further apart than half the smaller height are two rows, even
# when the lower one is further left.
dev_case idx-rows
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode "" Tag 100 160 400 260)$(xnode "" Tag 600 100 900 200)$(xnode "" Tag 100 1000 400 1100)$(xnode "" Tag 600 1040 900 1140)")"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Tag", "index": 0 }' '{ "do": "assertText", "value": "Tag", "index": 1 }' \
  '{ "do": "assertText", "value": "Tag", "index": 2 }' '{ "do": "assertText", "value": "Tag", "index": 3 }'
run_flow "$case_dir/flow.json"
begin "index: a row is centres within half the smaller height; otherwise top to bottom"
status_is 0
has out.txt "assert (exact): 'Tag' index 0 on screen at 750 150"; has out.txt "assert (exact): 'Tag' index 1 on screen at 250 210"
has out.txt "assert (exact): 'Tag' index 2 on screen at 250 1050"; has out.txt "assert (exact): 'Tag' index 3 on screen at 750 1090"
verdict

# The frame around a control is not a second match: the tie rule of tapText.
dev_case idx-frame
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode "" Continue 0 200 1080 1200)" "$(xnode "" Continue 100 900 500 1000)" "$(xnode "" Continue 600 900 1000 1000)")"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Continue", "index": 1 }' '{ "do": "tapText", "value": "Continue", "index": 2 }'
run_flow "$case_dir/flow.json"
begin "index: a match that holds another match is its frame and does not count"
status_is 1; atap_is "800 950"
has out.txt "index 2 is out of range: 2 elements match 'Continue'"
verdict

# Off the screen and at zero size: not counted, as the single lookup ignores them.
dev_case idx-filters
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode opt "" 100 100 100 100)" "$(xnode opt "" 100 2600 500 2700)" "$(xnode opt "" 100 500 500 600)" "$(xnode opt "" 100 700 500 800)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "opt", "index": 1 }' '{ "do": "assertId", "value": "opt", "index": 2 }'
run_flow "$case_dir/flow.json"
begin "index: tapId and assertId skip zero size and off screen when counting"
status_is 1; atap_is "300 750"
has out.txt "tap id 'opt' index 1"
has out.txt "assert FAILED: index 2 is out of range: 2 elements with id 'opt' as closely as the best match on the screen"
verdict

# The shape of the issue: rows answered before stay above, and each row repeats
# the options by id. "in" names the first row with its id, so the lowest row is
# reached by the index alone: the options are counted down the screen.
X_ROWS="$(xnode row "" 0 300 1080 500)$(xnode opt Yes 100 350 500 450)$(xnode opt No 600 350 1000 450)$(xnode row "" 0 600 1080 800)$(xnode opt Yes 100 650 500 750)$(xnode opt No 600 650 1000 750)"
dev_case idx-lowest-row
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_ROWS")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "opt", "index": 3 }'
run_flow "$case_dir/flow.json"
begin "index: option 2 of the lowest of two rows is index 3 by id"
status_is 0; atap_is "800 700"
verdict

# "in" and "index" together: the index counts inside the element only.
dev_case idx-in
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode "" Yes 100 100 500 200)$(xnode card "" 0 300 1080 500)$(xnode "" Yes 600 350 1000 450)$(xnode "" Yes 100 350 500 450)")"
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Yes", "in": "card", "index": 1 }' '{ "do": "assertText", "value": "Yes", "in": "card", "index": 2 }'
run_flow "$case_dir/flow.json"
begin "index with in: counted inside the element, out of range names it"
status_is 1
has out.txt "assert (exact) in 'card': 'Yes' index 1 on screen at 800 400"
has out.txt "assert FAILED (exact match): index 2 is out of range: 2 elements match 'Yes' in the element with id 'card' as closely as the best match on the screen"
verdict

dev_case idx-wait
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode item "" 0 300 1080 400)")"
screen "$case_dir/adb/dump-2.xml" "$(sroot "$(xnode item "" 0 300 1080 400)$(xnode item "" 0 500 1080 600)")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "item", "index": 1, "timeout": 5 }' '{ "do": "waitForId", "value": "item", "index": 2, "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "index: waitForId waits for the second match, and its timeout says how many there were"
status_is 1
has out.txt "waitFor id, index 1: 'item' on screen at 540 550"
has out.txt "'item' not on screen after 1s - index 2 is out of range: 2 elements with id 'item' as closely as the best match on the screen"
verdict

dev_case idx-box
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode card "" 0 300 1080 400)$(xnode card "" 0 500 1080 700)")"
flow_file "$case_dir/flow.json" '{ "do": "assertBoxId", "value": "card", "index": 1, "box": { "minHeight": 200 } }'
run_flow "$case_dir/flow.json"
begin "index: assertBoxId measures the match it names"
status_is 0; has out.txt "assert box: id 'card' index 1 is 1080x200 at [0,500][1080,700]"
verdict

dev_case idx-optional
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_GRID")"
flow_file "$case_dir/flow.json" '{ "do": "optionalTapText", "value": "Continue", "index": 5 }'
run_flow "$case_dir/flow.json"
begin "index: optionalTapText past the last match skips and says how many matched"
status_is 0; no_atap
has out.txt "optional 'Continue' not present - skipped: index 5 is out of range: 3 elements match 'Continue'"
verdict

dev_case idx-clear
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode field "" 0 300 1080 400)$(xnode field "" 0 500 1080 600)")"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "field", "index": 2 }'
run_flow "$case_dir/flow.json"
begin "index: clearTextId past the last match touches nothing"
status_is 1; no_atap; has out.txt "index 2 is out of range: 2 elements with id 'field' as closely as the best match on the screen"
verdict

new_case idx-check
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Continue", "index": 1 }' '{ "do": "tapId", "value": "opt", "index": "0" }' \
  '{ "do": "assertText", "value": "Yes", "in": "card", "index": 2 }' '{ "do": "waitForId", "value": "item", "index": 1 }'
expect "check: index builds on the lookup verbs" 0 " - 4 steps" check "$case_dir/flow.json"

new_case idx-negative
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Continue", "index": -1 }'
expect "check: a negative index is refused" 1 "\"index\" is '-1' - it has to be a whole number from 0" check "$case_dir/flow.json"

new_case idx-fraction
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "opt", "index": 1.5 }'
expect "check: a fractional index is refused" 1 "\"index\" is '1.5' - it has to be a whole number from 0" check "$case_dir/flow.json"

new_case idx-bool
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "opt", "index": true }'
expect "check: a boolean index is refused" 1 "\"index\" is the number of the match, from 0" check "$case_dir/flow.json"

new_case idx-not
flow_file "$case_dir/flow.json" '{ "do": "assertNotText", "value": "Item", "index": 2 }'
expect "check: assertNotText with an index points to assertCount" 1 \
  "step 'assertNotText' does not take \"index\" - to say there are fewer than N matches use assertCount with \"op\": \"atMost\"" check "$case_dir/flow.json"

new_case idx-scroll
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Item", "index": 2 }'
expect "check: a verb that does not look one element up refuses an index" 1 \
  "step 'scrollToText' does not take \"index\" - only tapText, optionalTapText, tapId" check "$case_dir/flow.json"

ios_case ios-idx-tap
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(ilabel "" Continue 20,500,160,40)" "$(ilabel "" Continue 220,200,160,40)" "$(ilabel "" Continue 20,205,160,40)"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Continue", "index": 0 }' '{ "do": "tapText", "value": "Continue", "index": 1 }' \
  '{ "do": "tapText", "value": "Continue", "index": 2 }' '{ "do": "tapText", "value": "Continue", "index": 3 }'
run_ios "$case_dir/flow.json"
begin "index on iOS: the order of the screen, not of the list, and the same miss"
status_is 1
got="$(grep '^ui tap' "$case_dir/idb/log" | sed 's/^ui tap --udid FAKE-UDID //' | tr '\n' '|')"
[ "$got" = "100 225|300 220|100 520|" ] || no "taps were $got, wanted 100 225|300 220|100 520|"
has out.txt "index 3 is out of range: 3 elements match 'Continue' as closely as the best match on the screen"
verdict

ios_case ios-idx-id
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate opt Button 300 "" '["Button"]')" "$(istate opt Button 200 "" '["Button"]')" "$(istate opt Button 2000 "" '["Button"]')"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "opt", "index": 1 }' '{ "do": "assertId", "value": "opt", "index": 2 }'
run_ios "$case_dir/flow.json"
begin "index on iOS: assertId by id, off screen not counted"
status_is 1; has out.txt "assert id: 'opt' index 1 on screen at 200 322"
has out.txt "index 2 is out of range: 2 elements with id 'opt' as closely as the best match on the screen"
verdict

# ── how many match: assertCount (#47) ────────────────────────────────────────
X_ITEMS="$(xnode "" Item 0 300 1080 400)$(xnode "" Item 0 500 1080 600)$(xnode "" Item 0 2600 1080 2700)$(xnode "" Item 0 800 0 800)$(xnode "" "Item 3" 0 900 1080 1000)"

dev_case count-at-least
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_ITEMS")"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "op": "atLeast", "count": 2 }' \
  '{ "do": "assertCount", "value": "Item", "match": "contains", "op": "exact", "count": 3 }' \
  '{ "do": "assertCount", "value": "Item", "op": "atMost", "count": 2 }'
run_flow "$case_dir/flow.json"
begin "assertCount: off screen and zero size not counted, match as in assertText"
status_is 0; fake_used
has out.txt "assertCount (exact match): 2 elements match 'Item' on the screen, at least 2"
has out.txt "assertCount (contains match): 3 elements match 'Item' on the screen, exactly 3"
has out.txt "assertCount (exact match): 2 elements match 'Item' on the screen, at most 2"
verdict

dev_case count-fail
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_ITEMS")"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "op": "exact", "count": 3 }'
run_flow "$case_dir/flow.json"
begin "assertCount: a red step says how many were found, on the console and in the report"
status_is 1
has out.txt "assertCount (exact match) FAILED: 2 elements match 'Item' on the screen, expected exactly 3"
has res/flow.xml "2 elements match 'Item' on the screen, expected exactly 3"
verdict

dev_case count-one
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode "" Item 0 300 1080 400)")"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "op": "atLeast", "count": 2 }'
run_flow "$case_dir/flow.json"
begin "assertCount: the list of one that assertText passes on is red"
status_is 1; has out.txt "1 element matches 'Item' on the screen, expected at least 2"
verdict

dev_case count-id
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_ROWS")"
flow_file "$case_dir/flow.json" '{ "do": "assertCountId", "value": "opt", "op": "exact", "count": 4 }' '{ "do": "assertCountId", "value": "row", "op": "atMost", "count": 1 }'
run_flow "$case_dir/flow.json"
begin "assertCountId: by id, and atMost red with the number found"
status_is 1
has out.txt "assertCount id: 4 elements with id 'opt' on the screen, exactly 4"
has out.txt "assertCount id FAILED: 2 elements with id 'row' on the screen, expected at most 1"
verdict

dev_case count-cli
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_ITEMS")"
env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" assert-count Item assert atLeast 3 contains > "$case_dir/out" 2>&1
run_status=$?; sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"
begin "assert-count by hand"
status_is 0; has out.txt "assertCount (contains match): 3 elements match 'Item' on the screen, at least 3"
verdict

new_case count-check
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "op": "atLeast", "count": 2, "match": "contains" }' \
  '{ "do": "assertCountId", "value": "row", "op": "exact", "count": "0" }'
expect "check: assertCount and assertCountId build" 0 " - 2 steps" check "$case_dir/flow.json"

new_case count-no-op
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "count": 2 }'
expect "check: assertCount without an op is refused" 1 \
  "assertCount needs \"op\" (atLeast, exact or atMost) and \"count\"" check "$case_dir/flow.json"

new_case count-bad-op
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "op": "more", "count": 2 }'
expect "check: an unknown op is refused" 1 "\"op\" is \"more\" - use atLeast, exact or atMost" check "$case_dir/flow.json"

new_case count-negative
flow_file "$case_dir/flow.json" '{ "do": "assertCountId", "value": "row", "op": "exact", "count": -1 }'
expect "check: a negative count is refused" 1 "\"count\" is '-1' - it has to be a whole number from 0" check "$case_dir/flow.json"

new_case count-at-least-zero
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "op": "atLeast", "count": 0 }'
expect "check: atLeast 0 cannot fail and is refused" 1 "\"atLeast\" 0 passes on any screen" check "$case_dir/flow.json"

new_case count-op-elsewhere
flow_file "$case_dir/flow.json" '{ "do": "assertText", "value": "Item", "op": "atLeast" }'
expect "check: op on another verb is refused" 1 "step 'assertText' does not take \"op\" - only assertCount and assertCountId do" check "$case_dir/flow.json"

new_case count-id-match
flow_file "$case_dir/flow.json" '{ "do": "assertCountId", "value": "row", "op": "exact", "count": 1, "match": "contains" }'
expect "check: assertCountId takes no match" 1 "does not take a \"match\" - only assertText, assertNotText, assertCount, waitFor and waitForNotText do" check "$case_dir/flow.json"

ios_case ios-count
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(ilabel "" Item 20,100,360,40)" "$(ilabel "" Item 20,200,360,40)" "$(ilabel "" Item 20,2000,360,40)" "$(ilabel "" Item 20,300,0,0)"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Item", "op": "exact", "count": 2 }' '{ "do": "assertCount", "value": "Item", "op": "atLeast", "count": 3 }'
run_ios "$case_dir/flow.json"
begin "assertCount on iOS: the same filters, the same words"
status_is 1
has out.txt "assertCount (exact match): 2 elements match 'Item' on the screen, exactly 2"
has out.txt "assertCount (exact match) FAILED: 2 elements match 'Item' on the screen, expected at least 3"
verdict

# The review of #46/#47: the frame rule and the rank filter outside tapText,
# identical boxes, the order on iOS, an index with a state, the command line.
# rnode <class> <text> <desc> <clickable> <x1> <y1> <x2> <y2> [id] - an open node tag.
rnode(){ printf '<node index="0" text="%s" resource-id="%s" class="android.%s" package="com.example" content-desc="%s" checkable="false" checked="false" clickable="%s" enabled="true" focusable="%s" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[%d,%d][%d,%d]"' \
  "$2" "${9:+com.example:id/$9}" "$1" "$3" "$4" "$4" "$5" "$6" "$7" "$8"; }
# A pressable row whose label is on the row and on the text inside it.
rnrow(){ printf '%s>%s /></node>' "$(rnode view.ViewGroup "" Buy true 0 "$1" 1080 $(($1+100)))" "$(rnode widget.TextView Buy "" false 400 $(($1+30)) 680 $(($1+70)))"; }
# The same with one id on the wrapper and on the view inside it.
rnidrow(){ printf '%s>%s /></node>' "$(rnode view.ViewGroup "" "" true 0 "$1" 1080 $(($1+100)) buy)" "$(rnode widget.TextView "" "" false 400 $(($1+30)) 680 $(($1+70)) buy)"; }

dev_case idx-frame-assert
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(rnrow 300)$(rnrow 500)$(rnrow 700)")"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Buy", "op": "exact", "count": 3 }' '{ "do": "assertText", "value": "Buy", "index": 1 }'
run_flow "$case_dir/flow.json"
begin "frame rule by text: a row labelled on itself and on its text is one match"
status_is 0
has out.txt "assertCount (exact match): 3 elements match 'Buy' on the screen, exactly 3"
has out.txt "assert (exact): 'Buy' index 1 on screen at 540 550"
verdict

dev_case idx-frame-id
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(rnidrow 300)$(rnidrow 500)$(rnidrow 700)")"
flow_file "$case_dir/flow.json" '{ "do": "assertCountId", "value": "buy", "op": "exact", "count": 3 }' '{ "do": "tapId", "value": "buy", "index": 2 }'
run_flow "$case_dir/flow.json"
begin "frame rule by id: one id on a wrapper and its inner view is one match"
status_is 0; atap_is "540 750"
has out.txt "assertCount id: 3 elements with id 'buy' on the screen, exactly 3"
verdict

dev_case idx-same-box
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(rnode widget.FrameLayout Go "" true 100 300 500 400) />$(rnode widget.Button Go "" true 100 300 500 400) />")"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Go", "op": "exact", "count": 1 }' '{ "do": "tapText", "value": "Go", "index": 1 }'
run_flow "$case_dir/flow.json"
begin "two matches with the same box are one control"
status_is 1; no_atap
has out.txt "assertCount (exact match): 1 element matches 'Go' on the screen, exactly 1"
has out.txt "index 1 is out of range: 1 element matches 'Go' as closely as the best match on the screen"
verdict

dev_case idx-rank
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(rnode widget.TextView Continue "" false 100 300 500 400) />$(rnode widget.Button Continue "" true 100 900 500 1000) />$(rnode widget.Button Continue "" true 100 1100 500 1200) />")"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Continue", "index": 1 }' '{ "do": "tapText", "value": "Continue", "index": 2 }'
run_flow "$case_dir/flow.json"
begin "index: a caption that ranks lower is not counted, and the miss says so"
status_is 1; atap_is "300 1150"
has out.txt "index 2 is out of range: 2 elements match 'Continue' as closely as the best match on the screen, and 1 more matches less closely and is not counted"
verdict

dev_case idx-state
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(snode tab 300 false)" "$(snode tab 500 true)")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "tab", "index": 1, "selected": true, "timeout": 1 }' \
  '{ "do": "assertId", "value": "tab", "index": 1, "selected": true }' '{ "do": "assertId", "value": "tab", "index": 0, "selected": true }'
run_flow "$case_dir/flow.json"
begin "index with a state: the state of the match it names"
status_is 1
has out.txt "waitFor id, index 1: 'tab' on screen at 540 550"
has out.txt "assert id: 'tab' index 1 on screen at 540 550, selected"
has out.txt "assert FAILED: 'tab' is not selected"
verdict

dev_case idx-cli
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_GRID")"
env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" find Continue text exact centre "" abc > "$case_dir/out" 2>&1
run_status=$?; sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"
begin "an index that is not a whole number is refused by the lookup itself"
status_is 1; has out.txt "index must be a whole number from 0 to 999999, got 'abc'"; lacks out.txt "Traceback"
verdict

dev_case idx-cli-extra
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_GRID")"
env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  FAKE_ADB_DIR="$case_dir/adb" TMPDIR="$case_dir/tmp" "$YUKTI" tap-text Continue 10 -1 > "$case_dir/out" 2>&1
run_status=$?; sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"
begin "tap-text by hand takes no index: an extra argument is ignored and the first in the tree is tapped, as before"
status_is 0; atap_is "300 950"
verdict

new_case idx-too-big
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "x", "index": 1000000 }' 
expect "check: an index of more than six digits is refused" 1 "\"index\" is '1000000' - at most 999999" check "$case_dir/flow.json"

# iOS: a button labelled like the text inside it, two rows.
ibuy(){ printf '{"type":"Button","role_description":"button","AXUniqueId":"","AXLabel":"Buy","frame":{"x":0,"y":%s,"width":402,"height":60}}' "$1"; }
ios_case ios-idx-frame
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(ibuy 100)" "$(ilabel "" Buy 150,110,100,40)" "$(ibuy 200)" "$(ilabel "" Buy 150,210,100,40)"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Buy", "op": "exact", "count": 2 }' '{ "do": "assertText", "value": "Buy", "index": 1 }'
run_ios "$case_dir/flow.json"
begin "frame rule on iOS: a button and the label inside it are one match"
status_is 0
has out.txt "assertCount (exact match): 2 elements match 'Buy' on the screen, exactly 2"
has out.txt "assert (exact): 'Buy' index 1 on screen at 200 230"
verdict

ios_case ios-idx-state
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate tab Button 300 "" '["Button","Selected"]')" "$(istate tab Button 200 "" '["Button"]')"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "tab", "index": 1, "selected": true }' '{ "do": "assertId", "value": "tab", "index": 0, "selected": true }'
run_ios "$case_dir/flow.json"
begin "index with a state on iOS"
status_is 1; has out.txt "assert id: 'tab' index 1 on screen at 200 322, selected"
has out.txt "assert FAILED: 'tab' is not selected"
verdict

# The cross review of #46/#47: one index, one screen, the same element whatever
# the verb; a count inside one element; an index with nothing to count.
dev_case idx-rn-two-rows
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(rnrow 300)$(rnrow 500)")"
flow_file "$case_dir/flow.json" '{ "do": "assertCount", "value": "Buy", "op": "exact", "count": 2 }' \
  '{ "do": "assertText", "value": "Buy", "index": 1 }' '{ "do": "tapText", "value": "Buy", "index": 1 }'
run_flow "$case_dir/flow.json"
begin "frame rule: two pressable rows count 2, and assertText and tapText index 1 are the same row"
status_is 0
has out.txt "assertCount (exact match): 2 elements match 'Buy' on the screen, exactly 2"
has out.txt "assert (exact): 'Buy' index 1 on screen at 540 550"; atap_is "540 550"
verdict

dev_case count-in
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_ROWS")"
flow_file "$case_dir/flow.json" '{ "do": "assertCountId", "value": "opt", "in": "row", "op": "exact", "count": 2 }' \
  '{ "do": "assertCount", "value": "Yes", "in": "row", "op": "exact", "count": 1 }' \
  '{ "do": "assertCountId", "value": "opt", "in": "missing", "op": "atLeast", "count": 1 }'
run_flow "$case_dir/flow.json"
begin "assertCount with in: counted inside the element; a missing element is named"
status_is 1
has out.txt "assertCount id: 2 elements with id 'opt' in the element with id 'row' on the screen, exactly 2"
has out.txt "assertCount (exact match): 1 element matches 'Yes' in the element with id 'row' on the screen, exactly 1"
has out.txt "assertCount FAILED: no element with id 'missing'"
verdict

ios_case ios-count-in
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(ilabel row "" 0,100,402,60)" "$(ilabel opt "" 20,110,100,40)" "$(ilabel opt "" 200,110,100,40)" "$(ilabel opt "" 20,300,100,40)"
flow_file "$case_dir/flow.json" '{ "do": "assertCountId", "value": "opt", "in": "row", "op": "exact", "count": 2 }'
run_ios "$case_dir/flow.json"
begin "assertCountId with in on iOS"
status_is 0; has out.txt "assertCount id: 2 elements with id 'opt' in the element with id 'row' on the screen, exactly 2"
verdict

dev_case idx-zero
screen "$case_dir/adb/dump-1.xml" "$(sroot "$X_GRID")"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Nope", "index": 1 }'
run_flow "$case_dir/flow.json"
begin "index with no match at all: out of range with 0"
status_is 1; no_atap; has out.txt "index 1 is out of range: 0 elements match 'Nope' on the screen"
verdict

dev_case idx-zero-wait
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(xnode item "" 0 300 1080 300)")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "item", "index": 0, "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "index with no match: waitForId still says the namesake is at zero size"
status_is 1; has out.txt "'item' not on screen after 1s - at zero size [0,300][1080,300]"
verdict

# ── "index" with "in" on tapText and with "at" on tapId ──────────────────────
# tapText "in" (#146) and tapId "at" (#129) landed next to the index: the index
# counts inside the element, and the point is taken on the match it picks.
# Two "Details" links inside the note, one more below it, outside.
IX_NOTE="$(tnode consent-note "" 40,1000,1040,1300)"
IX_L1="$(lnode "Details" 100,1050,300,1100)"
IX_L2="$(lnode "Details" 600,1050,800,1100)"
IX_OUT="$(lnode "Details" 100,1500,300,1550)"

dev_case idx-in-tap
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IX_NOTE" "$IX_OUT" "$IX_L1" "$IX_L2"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Details", "in": "consent-note", "index": 1 }'
run_flow "$case_dir/flow.json"
begin "tapText in with index: the second match inside the element, the one outside not counted"
status_is 0; has out.txt "tap 'Details' in 'consent-note' index 1"; atap_is "700 1075"
verdict

dev_case idx-in-range
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$IX_NOTE" "$IX_OUT" "$IX_L1" "$IX_L2"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Details", "in": "consent-note", "index": 2 }'
run_flow "$case_dir/flow.json"
begin "tapText in with index past the last: counts inside the element, nothing tapped"
status_is 1; has out.txt "index 2 is out of range: 2 elements match 'Details' in the element with id 'consent-note' as closely as the best match on the screen"
no_atap
verdict

dev_case idx-in-part
screen "$case_dir/adb/dump-1.xml" "$IN_ROOT" "$LN_NOTE"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Terms of Use", "in": "consent-note", "index": 0 }'
run_flow "$case_dir/flow.json"
begin "tapText in with index: words that are only part of a longer text keep their own words, not 'out of range'"
status_is 1; has out.txt "'Terms of Use' is part of a longer text in the element with id 'consent-note' and has no element of its own to tap"
lacks out.txt "out of range"; no_atap
verdict

ios_case ios-idx-in-tap
tree "$case_dir/idb/desc-1.json" "$iroot" \
  '{"type":"Other","role_description":"group","AXUniqueId":"consent-note","AXLabel":null,"frame":{"x":10,"y":490,"width":370,"height":100}}' \
  '{"type":"Link","role_description":"link","AXUniqueId":null,"AXLabel":"Details","frame":{"x":30,"y":550,"width":100,"height":20}}' \
  '{"type":"Link","role_description":"link","AXUniqueId":null,"AXLabel":"Details","frame":{"x":200,"y":550,"width":100,"height":20}}' \
  '{"type":"Link","role_description":"link","AXUniqueId":null,"AXLabel":"Details","frame":{"x":30,"y":700,"width":100,"height":20}}'
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Details", "in": "consent-note", "index": 1 }'
run_ios "$case_dir/flow.json"
begin "tapText in with index on iOS: the second match inside the element"
status_is 0; has idb/log "ui tap --udid FAKE-UDID 250 560"; lacks idb/log "ui tap --udid FAKE-UDID 80 560"
verdict

# Two tracks 1000x80 under one id, at y 1000 and 1200.
dev_case idx-at
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)$(bnode track 40 1200 1040 1280)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "25%" }, "index": 1 }'
run_flow "$case_dir/flow.json"
begin "tapId at with index: the point on the second track"
status_is 0; taps_are "290 1240|"; has out.txt "tap id 'track' index 1 at 25% x 50% of 1000x80: 290,1240"
verdict

dev_case idx-at-range
screen "$case_dir/adb/dump-1.xml" "$(sroot "$(bnode track 40 1000 1040 1080)$(bnode track 40 1200 1040 1280)")"
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "25%" }, "index": 2 }'
run_flow "$case_dir/flow.json"
begin "tapId at with index past the last: says how many, nothing tapped"
status_is 1; has out.txt "index 2 is out of range: 2 elements with id 'track' as closely as the best match on the screen"; taps_are ""
verdict

ios_case ios-idx-at
tree "$case_dir/idb/desc-1.json" "$IAPP" "$(istate track Slider 200 "" '[]')" "$(istate track Slider 300 "" '[]')"
ipoint track 20 300 360 44
flow_file "$case_dir/flow.json" '{ "do": "tapId", "value": "track", "at": { "x": "25%" }, "index": 1 }'
run_ios "$case_dir/flow.json"
begin "tapId at with index on iOS: the point on the second slider, in points"
status_is 0; has idb/log "ui tap --udid FAKE-UDID 110 322"
verdict

# ── background, foreground, relaunch (#53) ──────────────────────────────────
# bg_case <name> - an Android case: variant "app" is com.example, installed,
# running as pid 4242 and in front.
bg_case(){ dev_case "$1"; app_cfg android package
  printf '%s\n' com.example > "$case_dir/adb/packages"; printf '4242' > "$case_dir/adb/app-pid"
  printf '  mCurrentFocus=Window{3c4d u0 com.example/com.example.MainActivity}\n' > "$case_dir/adb/focus"; }
run_bg(){ run_flow "$1" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"; }
LAUNCHER='  mCurrentFocus=Window{1a2b u0 com.android.launcher3/com.android.launcher3.Launcher}'

bg_case bg-and-back
flow_file "$case_dir/flow.json" '{ "do": "background", "value": 1 }' '{ "do": "foreground" }'
run_bg "$case_dir/flow.json"
begin "background and foreground: Home, the launcher in front for a second, the same process back"
status_is 0; has adb/log "shell input keyevent 3"; has adb/log "shell monkey -p com.example -c android.intent.category.LAUNCHER 1"
has out.txt "background: com.example behind com.android.launcher3 for 1 s"
has out.txt "foreground: com.example back in front, the same process (4242)"
verdict

bg_case bg-no-value
flow_file "$case_dir/flow.json" '{ "do": "background" }'
run_bg "$case_dir/flow.json"
begin "background with no value: to the home screen and left there"
status_is 0; has out.txt "behind com.android.launcher3 for 0 s"; lacks adb/log "monkey"
verdict

bg_case bg-home-ignored
touch "$case_dir/adb/home-ignored"
flow_file "$case_dir/flow.json" '{ "do": "background" }'
run_bg "$case_dir/flow.json"
begin "background: a Home that did not land fails the step"
status_is 1; has out.txt "background: com.example is still in front 5 s after Home"
verdict

bg_case bg-not-in-front
printf '%s\n' "$LAUNCHER" > "$case_dir/adb/focus"
flow_file "$case_dir/flow.json" '{ "do": "background" }'
run_bg "$case_dir/flow.json"
begin "background: an app that is not in front is refused, no Home pressed"
status_is 1; has out.txt "background: com.example is not in front - in front: com.android.launcher3 - there is nothing to send to the background"
lacks adb/log "keyevent 3"
verdict

bg_case fg-new-process
touch "$case_dir/adb/launch-restarts"
flow_file "$case_dir/flow.json" '{ "do": "background" }' '{ "do": "foreground" }'
run_bg "$case_dir/flow.json"
begin "foreground: an app that comes back as a new process fails - a cold start is not a return"
status_is 1; has out.txt "foreground: com.example came back as a new process (pid 4242, now 4243) - it was started afresh, not resumed"
verdict

bg_case fg-not-running
printf '' > "$case_dir/adb/app-pid"; printf '%s\n' "$LAUNCHER" > "$case_dir/adb/focus"
flow_file "$case_dir/flow.json" '{ "do": "foreground" }'
run_bg "$case_dir/flow.json"
begin "foreground: an app that is not running is not started, the step fails"
status_is 1; has out.txt "foreground: com.example is not running any more"; lacks adb/log "monkey"
verdict

bg_case fg-already-front
flow_file "$case_dir/flow.json" '{ "do": "foreground" }'
run_bg "$case_dir/flow.json"
begin "foreground: an app already in front fails - nothing was brought back"
status_is 1; has out.txt "foreground: com.example is already in front - there is nothing to bring back"; lacks adb/log "monkey"
verdict

bg_case fg-launch-ignored
touch "$case_dir/adb/launch-ignored"
flow_file "$case_dir/flow.json" '{ "do": "background" }' '{ "do": "foreground" }'
run_bg "$case_dir/flow.json"
begin "foreground: an app that did not come to the front fails with what is there"
status_is 1; has out.txt "foreground: com.example is not in front 10 s after it was called - in front: com.android.launcher3"
verdict

bg_case relaunch-android
flow_file "$case_dir/flow.json" '{ "do": "relaunch" }'
run_bg "$case_dir/flow.json"
begin "relaunch: force-stop, then the launcher intent, data untouched"
status_is 0; has adb/log "shell am force-stop com.example"; has adb/log "shell monkey -p com.example"; lacks adb/log "pm clear"
has out.txt "relaunch: com.example started again as a new process (4242 -> 5001), its data kept"
[ "$(grep -n 'force-stop com.example' "$case_dir/adb/log" | cut -d: -f1)" -lt "$(grep -n 'monkey -p com.example' "$case_dir/adb/log" | cut -d: -f1)" ] || no "the start came before the stop"
verdict

bg_case relaunch-not-stopped
touch "$case_dir/adb/stop-ignored"
flow_file "$case_dir/flow.json" '{ "do": "relaunch" }'
run_bg "$case_dir/flow.json"
begin "relaunch: the same process in front after it is a failure - nothing was stopped"
status_is 1; has out.txt "relaunch: com.example is the same process as before (4242) - it was not stopped"
verdict

bg_case bg-no-variant
flow_file "$case_dir/flow.json" '{ "do": "background" }'
run_flow "$case_dir/flow.json" YUKTI_CONFIG="$case_dir/cfg.json"
begin "background: a run with no variant says which variable to set"
status_is 1; has out.txt "background: this run does not know which app it is about - set \$YUKTI_VARIANT"; lacks adb/log "keyevent"
verdict

new_case bg-check
flow_file "$case_dir/ok.json" '{ "do": "background", "value": 5 }' '{ "do": "foreground" }' '{ "do": "relaunch" }'
expect "background, foreground, relaunch: the builder takes them" 0 " - 3 steps" check "$case_dir/ok.json"
flow_file "$case_dir/secs.json" '{ "do": "background", "value": "1.5" }'
expect "background: seconds that are not whole are refused" 1 "step 1 'background': \"value\" is how many whole seconds the app stays in the background, got '1.5'" check "$case_dir/secs.json"
flow_file "$case_dir/long.json" '{ "do": "background", "value": 6000 }'
expect "background: more than 600 seconds is refused" 1 "step 1 'background': 6000 seconds - the most is 600" check "$case_dir/long.json"
flow_file "$case_dir/fg.json" '{ "do": "foreground", "value": "qa" }'
expect "foreground: a value is refused - it acts on the app of the run" 1 "step 1 'foreground' does not take a \"value\" - it acts on the app of \$YUKTI_VARIANT" check "$case_dir/fg.json"
flow_file "$case_dir/rl.json" '{ "do": "relaunch", "value": "qa" }'
expect "relaunch: a value is refused - it acts on the app of the run" 1 "step 1 'relaunch' does not take a \"value\"" check "$case_dir/rl.json"

# iOS: the same app as "Example App", running as pid 4242, its tree with the
# app's root in front.
ibg_case(){ ios_case "$1"; mkdir -p "$case_dir/xcrun/Example.app"; app_cfg ios bundleId
  "$PY3" -c 'import plistlib, sys
with open(sys.argv[1], "wb") as fh: plistlib.dump({"CFBundleDisplayName": "Example App", "CFBundleName": "Example"}, fh)' "$case_dir/xcrun/Example.app/Info.plist"
  printf '%s' "$case_dir/xcrun/Example.app" > "$case_dir/xcrun/container"
  printf 'PID\tStatus\tLabel\n4242\t0\tUIKitApplication:com.example[1a2b][rb-legacy]\n' > "$case_dir/xcrun/launchctl"
  tree "$case_dir/idb/desc-1.json" '{"type":"Application","role_description":"application","AXLabel":"Example App","frame":{"x":0,"y":0,"width":402,"height":874}}'; }
run_ibg(){ run_ios "$1" PATH="$ROOT/tests/fake-sdk/xcrun-bin:$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"; }
PY3="$(command -v python3)"

ibg_case ios-bg-and-back
flow_file "$case_dir/flow.json" '{ "do": "background" }' '{ "do": "foreground" }'
run_ibg "$case_dir/flow.json"
begin "background and foreground on iOS: the Home button, simctl launch of the running app, the same process"
status_is 0; has idb/log "ui button HOME --udid FAKE-UDID"; has xcrun/log "simctl launch FAKE-UDID com.example"
has out.txt "background: com.example behind the home screen for 0 s"
has out.txt "foreground: com.example back in front, the same process (4242)"
verdict

ibg_case ios-fg-second-launch
printf '1' > "$case_dir/xcrun/launch-misses"
flow_file "$case_dir/flow.json" '{ "do": "background" }' '{ "do": "foreground" }'
run_ibg "$case_dir/flow.json"
begin "foreground on iOS: a launch that left the home screen in front is sent once more"
status_is 0; [ "$(grep -c '^simctl launch ' "$case_dir/xcrun/log")" = 2 ] || no "simctl launch ran $(grep -c '^simctl launch ' "$case_dir/xcrun/log") times, wanted 2"
has out.txt "foreground: com.example back in front"
verdict

ibg_case ios-fg-two-misses
printf '2' > "$case_dir/xcrun/launch-misses"
flow_file "$case_dir/flow.json" '{ "do": "background" }' '{ "do": "foreground" }'
run_ibg "$case_dir/flow.json"
begin "foreground on iOS: two launches that left the home screen fail the step, no third"
status_is 1; has out.txt "foreground: com.example is not in front after two launches - in front: the home screen"
[ "$(grep -c '^simctl launch ' "$case_dir/xcrun/log")" = 2 ] || no "simctl launch ran $(grep -c '^simctl launch ' "$case_dir/xcrun/log") times, wanted 2"
verdict

ibg_case ios-fg-new-process
touch "$case_dir/xcrun/launch-restarts"
flow_file "$case_dir/flow.json" '{ "do": "background" }' '{ "do": "foreground" }'
run_ibg "$case_dir/flow.json"
begin "foreground on iOS: a new process is not a return"
status_is 1; has out.txt "came back as a new process (pid 4242, now 4243)"
verdict

ibg_case ios-relaunch
flow_file "$case_dir/flow.json" '{ "do": "relaunch" }'
run_ibg "$case_dir/flow.json"
begin "relaunch on iOS: simctl launch with --terminate-running-process"
status_is 0; has xcrun/log "simctl launch --terminate-running-process FAKE-UDID com.example"
has out.txt "relaunch: com.example started again as a new process (4242 -> 4243), its data kept"; grep -q '^4243' "$case_dir/xcrun/launchctl" || no "the app was not started as a new process"
verdict

ibg_case ios-relaunch-not-stopped
touch "$case_dir/xcrun/terminate-ignored"
flow_file "$case_dir/flow.json" '{ "do": "relaunch" }'
run_ibg "$case_dir/flow.json"
begin "relaunch on iOS: a launch that kept the running process is a failure"
status_is 1; has out.txt "relaunch: com.example is the same process as before (4242) - it was not stopped"
verdict

ibg_case ios-bg-no-name
rm -f "$case_dir/xcrun/container"
flow_file "$case_dir/flow.json" '{ "do": "background" }'
run_ibg "$case_dir/flow.json"
begin "background on iOS: an app whose name cannot be read is refused before Home"
status_is 1; has out.txt "background: could not read the name of 'com.example' from its Info.plist on the simulator"; lacks idb/log "button HOME"
verdict

ibg_case ios-bg-home-ignored
touch "$case_dir/idb/home-ignored"
flow_file "$case_dir/flow.json" '{ "do": "background" }'
run_ibg "$case_dir/flow.json"
begin "background on iOS: a Home button that did not land fails the step"
status_is 1; has out.txt "background: com.example is still in front 5 s after Home"
verdict
# ── preparation, teardown and the fixture step (#55) ────────────────────────
# fx_case <name> - an Android case with a fixture service of its own
# (tests/fake-sdk/fixture-server) and a config whose variant "app" names it, the
# secret in $FX_TOKEN. The device's zone is Europe/Lisbon.
fx_case(){ local i=0; dev_case "$1"; mkdir -p "$case_dir/fx"
  "$ROOT/tests/fake-sdk/fixture-server" "$case_dir/fx" & fx_pid=$!
  while [ ! -s "$case_dir/fx/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  printf '{"variants":{"app":{"platform":"android","package":"com.example","fixtures":{"url":"http://127.0.0.1:%s/","secret":"FX_TOKEN"}}}}\n' \
    "$(cat "$case_dir/fx/port")" > "$case_dir/cfg.json"
  printf 'Europe/Lisbon' > "$case_dir/adb/timezone"; }
fx_end(){ touch "$case_dir/fx/stop"; wait "$fx_pid" 2>/dev/null || true; }
run_fx(){ local f="$1"; shift; run_flow "$f" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json" "$@"; }
# answer <fixture> <status> [body]
answer(){ printf '%s\n%s' "$2" "${3:-}" > "$case_dir/fx/answer-$1"; }
asked(){ grep -c "\"path\": \"/$1\"" "$case_dir/fx/requests" 2>/dev/null || true; }
NEWMAIL="new.user@example.invalid"
# A flow that prepares an account, checks its address is on the screen, and
# deletes it afterwards.
fx_flow(){ cat > "$case_dir/flow.json" <<JSON
{ "name": "flow",
  "prepare": [ { "fixture": "fresh-account", "with": { "plan": "basic" }, "bind": { "TEST_EMAIL": "account.email" } } ],
  "teardown": [ { "fixture": "delete-account", "with": { "email": "\${TEST_EMAIL}" } } ],
  "steps": [ { "do": "assertText", "value": "\${TEST_EMAIL}" } ] }
JSON
  screen "$case_dir/adb/dump-1.xml" "$(node TextView email "$NEWMAIL")"; }

fx_case fx-bind
fx_flow; answer fresh-account 200 "{\"account\": {\"email\": \"$NEWMAIL\"}}"; answer delete-account 200 '{}'
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token TEST_EMAIL=old.user@example.invalid
fx_end
begin "prepare: the bound value wins over the exported one and reaches the steps; the teardown gets it"
status_is 0; has out.txt "prepare 1: fixture 'fresh-account' - bound TEST_EMAIL"; has out.txt "assert (exact): '$NEWMAIL' on screen"
has fx/requests '"path": "/fresh-account", "auth": "Bearer synthetic-token", "tz": "Europe/Lisbon", "body": {"plan": "basic"}'
has fx/requests "\"path\": \"/delete-account\", \"auth\": \"Bearer synthetic-token\", \"tz\": \"Europe/Lisbon\", \"body\": {\"email\": \"$NEWMAIL\"}"
has out.txt "teardown 1: fixture 'delete-account'"; lacks out.txt "synthetic-token"
has res/flow.xml '<property name="outcome" value="passed"/>'
verdict

fx_case fx-500
fx_flow; answer fresh-account 500 '{"detail": "server error"}'; answer delete-account 200 '{}'
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "prepare: a fixture that answered 500 blocks the flow - no step runs, not a failure, and no stand-in reaches the teardown"
status_is 0; has out.txt "flow blocked: prepare 1: fixture 'fresh-account' answered 500 - none of its steps ran"
has out.txt "step 1 'assertText' skipped: blocked: prepare 1"; lacks adb/log "uiautomator dump"; lacks out.txt "server error"
has res/flow.xml "<skipped message=\"blocked: prepare 1: fixture 'fresh-account' answered 500\"/>"
has res/flow.xml '<property name="outcome" value="skipped"/>'; has res/flow.xml "<property name=\"reason\" value=\"blocked: prepare 1"
has out.txt "teardown: teardown 1: fixture 'delete-account' not called - \$TEST_EMAIL was never set"
[ "$(asked delete-account)" = 0 ] || no "the teardown was called with a value nobody bound"
has res/flow.xml "<system-err>teardown: teardown 1: fixture 'delete-account' not called"
verdict

fx_case fx-missing-field
fx_flow; answer fresh-account 200 '{"account": {}}'
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "prepare: an answer without the bound field blocks the flow, by the field's name"
status_is 0; has out.txt "flow blocked: prepare 1: fixture 'fresh-account' answered without 'account.email' - TEST_EMAIL stays unset"
verdict

fx_case fx-no-secret
fx_flow
run_fx "$case_dir/flow.json"
fx_end
begin "prepare: the secret the config names is not set - blocked, nothing sent"
status_is 0; has out.txt "fixture 'fresh-account' not called - \$FX_TOKEN, the access secret the config names, is not set"
file_absent fx/requests
verdict

fx_case fx-redirect
fx_flow; answer fresh-account 302 ''
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "prepare: a redirect is not followed - the secret stays with the address the config named"
status_is 0; has out.txt "fixture 'fresh-account' answered 302 (a redirect - fixtures are not followed elsewhere)"
[ "$(wc -l < "$case_dir/fx/requests")" -eq 1 ] || no "more than one request reached the service"
verdict

fx_case fx-unreachable
fx_flow; fx_end
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
begin "prepare: a service that does not answer blocks the flow"
status_is 0; has out.txt "flow blocked: prepare 1: fixture 'fresh-account' could not be reached"
verdict

fx_case fx-teardown-after-red
fx_flow; answer fresh-account 200 '{"account": {"email": "someone.else@example.invalid"}}'; answer delete-account 200 '{}'
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "teardown: runs after a step failed, with the value the preparation bound"
status_is 1; has fx/requests '"path": "/delete-account", "auth": "Bearer synthetic-token", "tz": "Europe/Lisbon", "body": {"email": "someone.else@example.invalid"}'
has res/flow.xml '<property name="outcome" value="failed"/>'
verdict

fx_case fx-teardown-fails
fx_flow; answer fresh-account 200 "{\"account\": {\"email\": \"$NEWMAIL\"}}"; answer delete-account 500 ''
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "teardown: one that failed is said and kept in the report, and the flow still passed"
status_is 0; has out.txt "teardown: teardown 1: fixture 'delete-account' answered 500"
has res/flow.xml "<system-err>teardown: teardown 1: fixture 'delete-account' answered 500</system-err>"
has res/flow.xml '<property name="outcome" value="passed"/>'
verdict

fx_case fx-step
screen "$case_dir/adb/dump-1.xml" "$(node TextView weight 70)"
flow_file "$case_dir/flow.json" '{ "do": "fixture", "value": "change-weight", "with": { "kg": 70, "note": "${FX_NOTE}" } }' '{ "do": "assertText", "value": "70" }'
answer change-weight 200 '{}'
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token FX_NOTE=from-the-flow
fx_end
begin "fixture step: called in the middle of the flow with its body, variables filled"
status_is 0; has fx/requests '"path": "/change-weight", "auth": "Bearer synthetic-token", "tz": "Europe/Lisbon", "body": {"kg": 70, "note": "from-the-flow"}'
has out.txt "fixture 'change-weight' called"
verdict

fx_case fx-step-blocked
screen "$case_dir/adb/dump-1.xml" "$(node TextView weight 70)"
flow_file "$case_dir/flow.json" '{ "do": "fixture", "value": "change-weight" }' '{ "do": "assertText", "value": "70" }'
answer change-weight 503 ''
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "fixture step: a fixture that failed blocks the rest of the flow, out loud and in the report"
status_is 0; has out.txt "step 1 'fixture' skipped: blocked: step: fixture 'change-weight' answered 503 - the rest of the flow is skipped with it"
has out.txt "step 2 'assertText' skipped: blocked:"; lacks adb/log "uiautomator dump"
has res/flow.xml '<property name="outcome" value="skipped"/>'
verdict

fx_case fx-typo-first
cat > "$case_dir/flow.json" <<'JSON'
{ "name": "flow", "prepare": [ { "fixture": "fresh-account", "bind": { "TEST_EMAIL": "email" } } ],
  "steps": [ { "do": "asertText", "value": "${TEST_EMAIL}" } ] }
JSON
answer fresh-account 200 '{"email": "x@example.invalid"}'
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "prepare: a typo in a step stops the flow before anything is made on the server"
status_is 1; has out.txt "unknown step 'asertText'"; file_absent fx/requests
verdict

fx_case fx-401
fx_flow; answer fresh-account 401 ''
run_fx "$case_dir/flow.json" FX_TOKEN=synthetic-token
fx_end
begin "prepare: 401 says which variable holds the secret"
status_is 0; has out.txt "fixture 'fresh-account' answered 401 - check the secret in \$FX_TOKEN"
verdict

dev_case fx-http-far
printf '{"variants":{"app":{"platform":"android","package":"com.example","fixtures":{"url":"http://fixtures.example.invalid/"}}}}\n' > "$case_dir/cfg.json"
flow_file "$case_dir/flow.json" '{ "do": "fixture", "value": "change-weight" }'
run_fx "$case_dir/flow.json"
begin "fixtures: plain http to another machine is refused as a mistake in the config"
status_is 1; has out.txt "the fixtures address is 'http://fixtures.example.invalid/' - it has to be https (http only to localhost)"
verdict

dev_case fx-no-address
printf '{"variants":{"app":{"platform":"android","package":"com.example"}}}\n' > "$case_dir/cfg.json"
flow_file "$case_dir/flow.json" '{ "do": "fixture", "value": "change-weight" }'
run_fx "$case_dir/flow.json"
begin "fixtures: a config with no address is a red, not a blocked flow"
status_is 1; has out.txt "nothing says where the fixtures are - put \"fixtures\": {\"url\": \"https://...\"} on variant 'app'"
verdict

new_case fx-check
cat > "$case_dir/ok.json" <<'JSON'
{ "name": "ok",
  "prepare": [ { "fixture": "fresh-account", "bind": { "YUKTI_FX_EMAIL": "email" } },
               { "fixture": "activate", "with": { "email": "${YUKTI_FX_EMAIL}" } } ],
  "teardown": [ { "fixture": "delete-account", "with": { "email": "${YUKTI_FX_EMAIL}" } } ],
  "steps": [ { "do": "type", "value": "${YUKTI_FX_EMAIL}" }, { "do": "fixture", "value": "change-weight", "with": { "kg": 70 } } ] }
JSON
expect "prepare: --check builds the steps with a stand-in for what a fixture binds" 0 " - 2 steps" \
  env -u YUKTI_FX_EMAIL "$YUKTI" flow --check "$case_dir/ok.json"
printf '{ "name": "b", "prepare": [ { "fixture": "x" } ], "steps": [ { "do": "wait", "value": "1" } ] }\n' > "$case_dir/block.json"
flow_file "$case_dir/inc.json" '{ "do": "include", "value": "block.json" }'
expect "prepare: a block that carries it is refused" 1 "block 'block.json' carries \"prepare\" - only the flow file itself does" check "$case_dir/inc.json"
printf '{ "name": "t", "teardown": [ { "fixture": "x", "bind": { "A": "a" } } ], "steps": [ { "do": "wait", "value": "1" } ] }\n' > "$case_dir/tbind.json"
expect "teardown: bind is refused - nothing runs after it" 1 "teardown 1: 'bind' is not a key a teardown call takes" check "$case_dir/tbind.json"
printf '{ "name": "n", "prepare": [ { "fixture": "../admin" } ], "steps": [ { "do": "wait", "value": "1" } ] }\n' > "$case_dir/name.json"
expect "prepare: a fixture name that is a path is refused" 1 "prepare 1: \"fixture\" is the name of a fixture" check "$case_dir/name.json"
printf '{ "name": "u", "prepare": [ { "fixture": "x", "with": { "a": "${YUKTI_FX_UNSET}" } } ], "steps": [ { "do": "wait", "value": "1" } ] }\n' > "$case_dir/unset.json"
expect "prepare: a variable nobody sets or binds is refused" 1 "prepare 1: \$YUKTI_FX_UNSET is not set in the environment, and no call before this one binds it" \
  env -u YUKTI_FX_UNSET "$YUKTI" flow --check "$case_dir/unset.json"
flow_file "$case_dir/sbind.json" '{ "do": "fixture", "value": "x", "bind": { "A": "a" } }'
expect "fixture step: bind is refused - the steps after it are built before it runs" 1 "a fixture step binds nothing" check "$case_dir/sbind.json"
flow_file "$case_dir/sname.json" '{ "do": "fixture", "value": "a/b" }'
expect "fixture step: a name with a slash is refused" 1 "step 1 'fixture': \"value\" is the name of a fixture" check "$case_dir/sname.json"
flow_file "$case_dir/with.json" '{ "do": "tapText", "value": "x", "with": { "a": "b" } }'
expect "with: still refused on a step that is not include or fixture" 1 "only include and fixture take it" check "$case_dir/with.json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
