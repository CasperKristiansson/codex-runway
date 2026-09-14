# Codex Runway

A native macOS menu-bar app for tracking Codex account rate-limit windows.

## What it does

- Discovers the currently signed-in Codex account and keeps each identity in its own row.
- Shows usage, reset time, available reset credits, and saved refresh time.
- Refreshes the signed-in account on launch, every 15 minutes while running (even with the menu closed), and after wake.
- Shows all discovered accounts together; other accounts retain their last saved status and update time until signed in again.
- Shows a compact combined balance graph spanning 2 past days and at least 2 upcoming days, expanding through each account’s next reset, while retaining 30 days of history.
- Weights Pro 20× as 4 capacity units and Pro 5× as 1. Other plans need a supported plan label before pooling.
- Estimates average daily consumption by summing observed weighted usage across accounts and dividing once by a shared calendar window: from the earliest usable interval in the available history, up to 30 days, through now. Overnight, idle time, and gaps between account sessions count in this shared denominator; switching accounts does not multiply the rate. Reset and plan-change deltas are excluded; boundary intervals are prorated. Each account needs at least two hours of usable history; the average is labelled with its actual time span rather than assuming a full month of data. Unobserved consumption cannot be reconstructed, so sparse or stale readings can understate the rate. The projection assumes that average daily usage continues and that the nearest-resetting account is used first.
- Marks observed and scheduled resets and keeps upcoming reset dates in view. A horizontal guide shows the estimated balance before the next reset; hover shows the value, date and time at that point. Older saved balances can support an estimate when enough usage history exists. Forecasts pause for missing or overdue balances, incompatible windows, and exhausted reported secondary limits. This estimates the tracked allowance, not guaranteed access through every service limit.
- Keeps 30 days of snapshots locally; discarded older history cannot be restored. History connects saved readings by interpolation, and inactive balances remain last-known readings.
- Shows read-only account details in Settings, with Remove, Move up and Move down controls. Accounts are discovered automatically when refreshed.

## Privacy

Data stays local. Codex Runway uses the local Codex App Server's read-only account and rate-limit methods; it does not read browser cookies, store passwords, switch accounts, or use a cloud service.

## Build

Requires macOS and Swift.

```zsh
./scripts/test.sh
./scripts/build-app.sh
open "dist/Codex Runway.app"
```

The build script creates an ad-hoc-signed local app bundle in `dist/`.
