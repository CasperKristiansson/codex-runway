# Codex Runway

A native macOS menu-bar planner for several personal Codex accounts.

## V1 scope

- Discovers each distinct signed-in account and adds it as its own row. There is no account-count or plan-tier limit.
- Stores local, account-labelled rate-limit snapshots: usage percentage, next reset, banked resets, and refresh time.
- Refreshes only the currently signed-in Codex account through the local Codex App Server's read-only `account/read` and `account/rateLimits/read` methods. Email and backend account ID identify a row; plan tier is display data only.
- Lets an account remain visible but be excluded from planning.
- Forecasts whether the selected account will last until its next reset from saved snapshots in the same reset window.

V1 intentionally has no five-hour limit display, browser-session access, automated account switching, profile-token graph, or cloud service.

## Run

```zsh
cd /Users/casperkristiansson/programming/General/projects/active/tools/codex-runway
swift run CodexRunway
```

Use **Refresh current** while an account is signed in to Codex. If its email/account ID has not been seen before, Codex Runway adds a row; it never uses a shared tier such as Pro 20× to decide which row to update. Use **Settings** to rename, exclude from planning, or remove stale legacy rows.

## Test

```zsh
./scripts/test.sh
```

## Package as a menu-bar app

```zsh
./scripts/build-app.sh
open "dist/Codex Runway.app"
```

The bundle is ad-hoc signed for local use and is not notarized.
