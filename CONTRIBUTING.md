# Contributing to YUKTI

YUKTI is a single, dependency-light Bash CLI (`yukti`) plus JSON flow files. Keep it that way.

## Principles
- **Portable:** macOS + Apple tools + `idb` + system `python3`. No heavy runtimes.
- **AI-optional:** the core never requires an AI key. Flows run deterministically; agents are a layer on top.
- **Expo-optional:** the EAS adapter is a plugin, never a hard dependency.

## Adding features
- New CLI command → add to the `case` dispatcher and `usage()`.
- New flow step → add to the `flow()` runner + document it in `docs/RUNBOOK.md`.
- Prefer `tapText` (accessibility-label lookup) over raw coordinates in flows so they survive layout changes.

## Testing a change
```bash
./yukti doctor
YUKTI_CONFIG=examples/example.config.json ./yukti up qa
YUKTI_CONFIG=examples/example.config.json ./yukti flow flows/example-login.json
```

## Scope
Bug fixes, new flow steps, more device presets, Android (via `adb`) support, and richer
reporting are all welcome. Keep PRs focused. MIT licensed.
