# Codex Runway

A native macOS menu-bar app for tracking Codex account rate-limit windows.

## What it does

- Discovers the currently signed-in Codex account and keeps each identity in its own row.
- Shows usage, reset time, available reset credits, and saved refresh time.
- Refreshes the signed-in account on launch, every 15 minutes while running (even with the menu closed), and after wake.
- Shows enabled accounts together; other accounts retain their last saved status and update time until signed in again. Once a known reset time passes, the card and combined balance assume a full refill, mark it as "Reset assumed", and show the next reset as unknown until a successful refresh. No account switching is required to apply this assumption.
- Shows a compact combined balance graph spanning 2 past days and at least 2 upcoming days, expanding through each account’s next reset, while retaining one year (365 days) of history.
- Switches between the graph and an interval table in a shared seven-row-height display area, so changing ranges or views does not move the open panel. The selected range controls adaptive table intervals from 10 minutes through one day, capped at seven history rows and aligned to clean clock boundaries; each row keeps consumption visible across resets and marks resets separately. Overview scrolls within the same area to show its upcoming account resets, with a slim indigo position indicator.
- The graph range menu offers Overview, 1h, 6h, 1d, 3d and 7d, and remembers the selection. Forecast status, pace and averaging context remain visible in every range, while Overview alone includes prediction and future resets on the full capacity scale. The other ranges end at now, show historical resets, and zoom their balance scale to visible values. Saved points remain connected across refresh gaps. Hovering near a reset identifies its account and whether it is confirmed or assumed. A persistent switch changes graph labels between internal units and percentages, normalized so Pro 20× is 100% and Pro 5× is 25%; combined capacity can therefore exceed 100%.
- Weights Pro 20× as 4 capacity units and Pro 5× as 1. Other plans need a supported plan label before pooling.
- Estimates average daily consumption by summing observed weighted usage across accounts and dividing once by a shared calendar window: from the earliest usable interval in the available history, up to 30 days, through now. Overnight, idle time, and gaps between account sessions count in this shared denominator; switching accounts does not multiply the rate. Reset and plan-change deltas are excluded; boundary intervals are prorated. Each account needs at least two hours of usable history; the average is labelled with its actual time span rather than assuming a full month of data. Unobserved consumption cannot be reconstructed, so sparse or stale readings can understate the rate. The projection preserves that daily average but learns when usage happens during the day. It uses same-window intervals no longer than two hours from the retained history, merges overlapping observation time across accounts, and shrinks sparsely observed clock hours toward the pooled rate. Learning requires at least 24 observed hours spanning 48 hours; until then it uses a steady rate. Missing observations are not treated as idle time. The nearest-resetting account is used first.
- When that pace would exhaust the combined balance, the warning shows how early it happens and the projected deficit at the next reset in the selected units or percentage scale.
- Marks observed, assumed and scheduled resets and keeps known upcoming reset dates in view. A horizontal guide shows the estimated balance before the next reset; hover shows the value, date and time at that point. Older saved balances can support an estimate when enough usage history exists. Passed resets are derived from saved readings, never written as real usage snapshots or included in the consumption average. Their next reset dates remain unknown: the forecast schedules only known future resets, or shows a two-day burn estimate without refills if all dates are unknown. Forecasts still pause for missing balances, incompatible windows, and exhausted reported secondary limits. This estimates the tracked allowance, not guaranteed access through every service limit.
- Keeps one year of quota snapshots and profile daily activity locally; previously discarded history cannot be restored. The daily pace still averages the latest 30 days; the time-of-day pattern can use all retained quota history. Forecast demand is applied at local-hour boundaries, including daylight-saving transitions; an ordinary 24-hour day preserves the daily total, while a 23/25-hour transition day follows its actual clock hours. History connects saved readings by interpolation, and inactive balances remain last-known readings.
- Shows read-only account details in Settings, with Active/Inactive, Move up and Move down controls. Inactive accounts retain their saved history and order but are excluded from the dashboard and combined graph. Refresh does not reactivate them. Accounts are discovered automatically when refreshed.
- Opens an account's saved History directly when its dashboard card is clicked.
- Starts as a background-only menu-bar app without opening Settings. A transient launch refresh failure retries once after 10 seconds and does not replace already-saved account status with an error.
- Adds a Profile tab with individual profiles or a combined view of active accounts: lifetime tokens, peak daily tokens, longest-running turn (labelled Longest chat), streaks, and a year heatmap with Daily, Weekly and Cumulative modes.
- On every 15-minute refresh, launch and wake, checks whether the current account's last successful profile fetch is at least six hours old (or missing). Only then calls `account/usage/read`; manual Refresh profile bypasses the six-hour check. Failed requests preserve saved data and remain eligible for the next check. Other accounts show cached profiles; the app never switches authentication.
- Profile activity can lag by roughly six hours independently of fetch time. Revised day totals replace earlier totals for that date; older omitted days remain saved for one year. Combined lifetime tokens are summed without plan weighting, longest chat is the maximum, and peak/streaks are calculated from merged daily activity within the available year. The combined header reports how many profiles are available; missing statistics are not presented as zero. The heatmap has no explanatory footer: hovering a cell highlights it and shows its date and exact token count (weekly/cumulative totals in those modes). Refresh errors appear in a warning icon beside Refresh. It does not fetch display names, usernames or avatars.

- Saves immutable local forecast comparisons at most once per three-hour UTC bucket after successful quota refreshes. Records retain the starting observations, model version, time zone, 3/6/12/24/48-hour demand, projected exhaustion, and pre/post-reset balances. The displayed model uses the learned daily pattern; a constant-rate baseline and a 50/50 blend with the latest 72-hour pace run only in shadow. No weekday/weekend assumptions or token-to-quota conversion are applied. Records expire after one year and live in `~/Library/Application Support/Codex Runway/Forecasts`. Recording failures leave quota refreshes and displayed forecasts intact and are logged locally.

## Forecast evaluation

Reusable analysis tools are in `research/forecast/`. Private usage exports, generated results, and personal reports belong in the Git-ignored `research/forecast/local/` directory; the analysis tool writes there by default. After the app has collected forecast records and subsequent quota readings, compare prospective errors with:

```zsh
python3 research/forecast/score_journal.py
```

The scorer reports MAE, RMSE, bias, and disjoint-target results. It requires at least 80% observation coverage from intervals at most two hours long. These are **observed-consumption** scores, not proof of full account coverage or calibrated exhaustion probabilities; missing accounts, pending targets, long gaps and resets are never scored as zero demand.

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
