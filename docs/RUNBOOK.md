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
`type`, `clearText {x,y}`, `assertText`, `launch`. Coordinates are **points**
(iPhone 16 Pro = 402×874). Prefer `tapText` (finds by accessibility label) over
raw coords so flows survive layout changes. `${VARS}` in `value` expand from env.

Discover labels/coords for a screen:
```bash
~/yukti/yukti ui | python3 -m json.tool | less      # accessibility tree
~/yukti/yukti find "Sign In"                         # -> "201 705"
```

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
