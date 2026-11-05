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

dev_case clear-other-shape
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 0,300,1080,420)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a focused field of another width is another field"
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
lacks idb/log "ui key"
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
  "step 1 'tapId': step 'tapId' does not take \"in\" - only assertText, assertNotText, waitFor, tapText do" check "$case_dir/flow.json"

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
status_is 0; reads_are 1; has out.txt "'sheet' gone from the screen after 0s"
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
status_is 0; has out.txt "'btn' gone from the screen after 0s"
verdict

new_case gone-in
flow_file "$case_dir/flow.json" '{ "do": "waitForNotText", "value": "Saving", "in": "sheet" }'
expect "check: waitForNotText does not take \"in\" yet" 1 \
  "step 'waitForNotText' does not take \"in\" - only assertText, assertNotText, waitFor do" check "$case_dir/flow.json"

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
status_is 0; has out.txt "'Saving' gone from the screen after 0s"
verdict

dev_case gone-id-match
flow_file "$case_dir/flow.json" '{ "do": "waitForNotId", "value": "sheet", "match": "contains" }'
run_flow "$case_dir/flow.json"
begin "waitForNotId: a match is refused, it matches the id exactly"
status_is 1; has out.txt "does not take a \"match\" - only assertText, assertNotText, waitFor and waitForNotText do"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
