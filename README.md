# YUKTI

**Smart mobile-app QA automation.** Point it at your React Native / Expo iOS app and
it builds a **signed simulator app**, runs your **test cases**, and (optionally) lets
any AI agent drive it — all on your Mac's iOS Simulator. No BrowserStack, no cloud
device farm, no physical devices.

> *Yukti* (युक्ति) is Sanskrit for "smart thinking / ingenuity." YUKTI runs the
> **Talos** test-case engine (named for the bronze automaton of Greek myth — an
> automated guardian).

```bash
yukti up qa                     # build + sign + boot + install + launch, one shot
yukti flow flows/example-login.json  # run a deterministic test case
```

---

## Why

The iOS Simulator on your Mac is free and instant. The hard parts are (a) getting a
*signed, installable* simulator build out of a real RN/Expo app and (b) *driving* it
programmatically. YUKTI does both and bakes in the non-obvious fixes that otherwise
cost a team a day each:

| Gotcha | What YUKTI does |
| --- | --- |
| RN/Metro breaks on bleeding-edge Node | pins **node@22** |
| Vendor SDKs (ML Kit, some BLE SDKs) ship **device-only** static libs with no arm64-simulator slice → linker fails on Apple Silicon | `yukti scan` finds them; `excludeIosAutolink` drops them for the sim build |
| An **unsigned** sim build strips entitlements → Firebase/keychain fails (`SecItemCopyMatching -34018`) → **login silently 401s** with valid creds | builds **ad-hoc signed** (`CODE_SIGN_IDENTITY="-"`) so keychain/entitlements work — **no Apple cert or provisioning profile needed for a simulator** |
| Apple-Silicon sims need **arm64**; an x86_64 build won't install | forces `ARCHS=arm64` |
| `idb` bulk text-entry silently **drops characters** | types **char-by-char** |
| `EXPO_PUBLIC_*` inlined at bundle time; some SDKs throw on empty keys | per-variant `.env`; documented placeholders |

That signing row is the killer: the app *looks* built, but every authenticated request
401s and you blame the backend. It's the missing keychain entitlement on an unsigned build.

## AI is optional — two ways to test

1. **Deterministic flows** (the Talos engine) — `yukti flow <file.json>`. Zero AI, runs
   anywhere, CI-ready. This is your regression suite.
2. **AI-driven exploration** — any computer-use agent (**Claude Code**, **OpenAI**, or your
   own) drives the primitives. YUKTI is model-agnostic: it just exposes *see* and *act*.

```bash
yukti shot            # screenshot → the agent reads the PNG
yukti ui              # accessibility tree (labels + point coords)
yukti find "Sign In"  # → "201 705"
yukti tap 201 705 ; yukti type "hello"
```

## Install

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # full Xcode
xcodebuild -downloadPlatform iOS                                  # iOS runtime
brew install node@22 cocoapods watchman
brew trust facebook/fb && brew install idb-companion
/usr/bin/python3 -m pip install --user fb-idb
git clone https://github.com/karlmehta/yukti && cd yukti && chmod +x yukti
./yukti doctor        # verifies everything and tells you what's missing
```

## Quick start

```bash
cd your-rn-app
yukti init            # writes yukti.config.json — set schemes/bundleIds/env per variant
yukti scan            # (optional) find device-only libs to exclude
yukti up qa           # build + boot + install + launch
export TEST_EMAIL=... TEST_PASSWORD=...
yukti flow flows/example-login.json
```

See [`examples/example.config.json`](examples/example.config.json) for a full real config
and [`flows/`](flows/) for template flows (login, form entry) to customize for your app.

## Commands

```
yukti doctor            check/guide the toolchain
yukti init              write a starter yukti.config.json
yukti scan              list device-only frameworks (no arm64-sim slice) to exclude
yukti build <variant>   build a signed arm64 simulator .app (local)
yukti pull  <variant>   pull an OFFICIAL simulator build from EAS (needs EXPO_TOKEN)
yukti boot              create/boot the simulator
yukti up    <variant>   build + boot + install + launch
yukti flow  <file>      run a deterministic flow (Talos engine)
yukti shot | ui | find "<label>" | tap <x> <y> | type "<text>" | clear <x> <y>
```

## CI

`.github/workflows/yukti-qa.yml` runs the whole thing on GitHub **macOS runners** —
build → boot → run flows → upload screenshots + video, on every PR. QA team guide:
[`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## Optional: official EAS builds

Core is Expo-free. If you use EAS, `yukti pull <variant>` fetches a real simulator
build (add a `simulator` profile with `ios.simulator: true` to `eas.json`, set
`EXPO_TOKEN`). It's a plugin — never a dependency.

## License

MIT — see [LICENSE](LICENSE). Built by Karl Mehta.
