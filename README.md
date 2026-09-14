# Codex Runway

A native macOS menu-bar app for tracking Codex account rate-limit windows.

## What it does

- Discovers the currently signed-in Codex account and keeps each identity in its own row.
- Shows usage, reset time, available reset credits, and saved refresh time.
- Refreshes the signed-in account on launch, every 15 minutes while running (even with the menu closed), and after wake.
- Shows enabled accounts together; other accounts retain their last saved status and update time until signed in again. Once a known reset time passes, the card and combined balance assume a full refill, mark it as "Reset assumed", and show the next reset as unknown until a successful refresh. No account switching is required to apply this assumption.
- Shows a compact combined balance graph spanning 2 past days and at least 2 upcoming days, expanding through each account’s next reset, while retaining one year (365 days) of history.
- Weights Pro 20× as 4 capacity units and Pro 5× as 1. Other plans need a supported plan label before pooling.
- Estimates average daily consumption by summing observed weighted usage across accounts and dividing once by a shared calendar window: from the earliest usable interval in the available history, up to 30 days, through now. Overnight, idle time, and gaps between account sessions count in this shared denominator; switching accounts does not multiply the rate. Reset and plan-change deltas are excluded; boundary intervals are prorated. Each account needs at least two hours of usable history; the average is labelled with its actual time span rather than assuming a full month of data. Unobserved consumption cannot be reconstructed, so sparse or stale readings can understate the rate. The projection assumes that average daily usage continues and that the nearest-resetting account is used first.
- Marks observed, assumed and scheduled resets and keeps known upcoming reset dates in view. A horizontal guide shows the estimated balance before the next reset; hover shows the value, date and time at that point. Older saved balances can support an estimate when enough usage history exists. Passed resets are derived from saved readings, never written as real usage snapshots or included in the consumption average. Their next reset dates remain unknown: the forecast schedules only known future resets, or shows a two-day burn estimate without refills if all dates are unknown. Forecasts still pause for missing balances, incompatible windows, and exhausted reported secondary limits. This estimates the tracked allowance, not guaranteed access through every service limit.
- Keeps one year of quota snapshots and profile daily activity locally; previously discarded history cannot be restored. The forecast still averages the latest 30 days. History connects saved readings by interpolation, and inactive balances remain last-known readings.
- Shows read-only account details in Settings, with Active/Inactive, Move up and Move down controls. Inactive accounts retain their saved history and order but are excluded from the dashboard and combined graph. Refresh does not reactivate them. Accounts are discovered automatically when refreshed.
- Adds a Profile tab with individual profiles or a combined view of active accounts: lifetime tokens, peak daily tokens, longest-running turn (labelled Longest chat), streaks, and a year heatmap with Daily, Weekly and Cumulative modes.
- On every 15-minute refresh, launch and wake, checks whether the current account's last successful profile fetch is at least six hours old (or missing). Only then calls `account/usage/read`; manual Refresh profile bypasses the six-hour check. Failed requests preserve saved data and remain eligible for the next check. Other accounts show cached profiles; the app never switches authentication.
- Profile activity can lag by roughly six hours independently of fetch time. Revised day totals replace earlier totals for that date; older omitted days remain saved for one year. Combined lifetime tokens are summed without plan weighting, longest chat is the maximum, and peak/streaks are calculated from merged daily activity within the available year. The combined header reports how many profiles are available; missing statistics are not presented as zero. The heatmap has no explanatory footer: hovering a cell highlights it and shows its date and exact token count (weekly/cumulative totals in those modes). Refresh errors appear in a warning icon beside Refresh. It does not fetch display names, usernames or avatars.

## Privacy

Saved data stays local. Codex Runway uses the local Codex App Server's read-only account, rate-limit and profile-usage methods, which fetch data from OpenAI; it does not read browser cookies, store passwords, switch accounts, or send data to a separate cloud service. Profile usage uses the experimental API capability and requires a Codex version that supports `account/usage/read`.

## Build

Requires macOS and Swift.

```zsh
./scripts/test.sh
./scripts/build-app.sh
open "dist/Codex Runway.app"
```

The build script creates an ad-hoc-signed local app bundle in `dist/`.
