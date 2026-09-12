# Codex Runway

A native macOS menu-bar app for tracking Codex account rate-limit windows.

## What it does

- Discovers the currently signed-in Codex account and keeps each identity in its own row.
- Shows usage, reset time, available reset credits, and saved refresh time.
- Estimates whether an account is likely to last until its next reset from snapshots in the current window.
- Lets you rename accounts or exclude them from planning without hiding them.

## Privacy

Data stays local. Codex Runway uses the local Codex App Server's read-only account and rate-limit methods; it does not read browser cookies, store passwords, switch accounts, or use a cloud service.

## Build

Requires macOS and Swift.

```zsh
swift run CodexRunway
./scripts/test.sh
./scripts/build-app.sh
```

The build script creates an ad-hoc-signed local app bundle in `dist/`.
