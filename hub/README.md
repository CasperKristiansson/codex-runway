# Codex Runway hub

This responsive HTML interface is another presentation of native Runway. It opens on Overview and keeps Settings, History and Analytics within the same embedded surface. The native menu remains a compact quick view; the native Settings window includes a larger Overview made from its existing graph and account cards.

## Install and open

1. Build the bundle as described in the repository README. Quit **Runway only** while no account operation is running, replace `/Applications/Codex Runway.app` with `dist/Codex Runway.app`, and start its existing LaunchAgent or open the installed app. Keep Codex running. Do not launch a second app over an older pre-hub copy.
2. Register and install the plugin:

   ```zsh
   codex plugin marketplace add /Users/casperkristiansson/programming/codex-runway/hub
   codex plugin add codex-runway@codex-runway-local
   ```
3. Open Codex Runway from the sidebar app entry or `codex://plugins/codex-runway@codex-runway-local/app/open_codex_runway`. Overview is the default. Reopen/reload a previously open plugin surface to fetch updated assets.

The stdio command in `.mcp.json` points at this checkout's `hub/server.py`. It does not depend on Codex being launched by a special script. On another machine, update that absolute server path. Python 3.9+ is sufficient for the adapter. Node is required only when rebuilding the committed self-contained bundle. The installed package has a separate `codex-runway` identity and `open_codex_runway` global entrypoint; Thread Desk is not modified or required.

If Runway is unavailable, the hub says so and retains any last successful displayed snapshot. **Open native app** targets `/Applications/Codex Runway.app` when no bridge responds, or opens the native Overview window through the running bridge. This does not silently replace an older running app: install/relaunch the updated Runway first.

## State and contract

`RunwayStore` remains the only owner of account preferences, refreshes, forecasting, saved login operations and native recovery. `RunwayBackupManager` remains the backup owner. There is no web/adapter database, authentication implementation, browser storage, or JavaScript forecast. Graph settings use one observable native preferences object across all three surfaces.

The running app owns `~/Library/Application Support/Codex Runway/Bridge/hub-v1.sock`. The directory is 0700, socket 0600, peers must have the same UID, and an exclusive lease prevents two new app instances from writing state. The server rejects symlink endpoints, unknown request keys, invalid versions and identifiers. A single JSON request and response use newline framing, bounded 16 KiB requests / 4 MiB replies, four concurrent transport clients, and read/write deadlines. This is private local IPC for this user, not an authorization boundary against other programs running as that user.

Version 1 requests are either:

- `snapshot`: a local read, optionally scoped to `section`, account UUID, and 7/30/365 days. An omitted account means all enabled accounts. Cached reads never refresh OpenAI data or touch credentials. Account status, refresh eligibility, progress/errors, native recovery state, backup state and operation receipts are included. Forecasts are calculated in Swift, cached for at most 60 seconds, and invalidated on native state or display-preference changes.
- `command`: a validated explicit action plus UUID `requestID`. Account/login IDs are checked against current native state, then admission is rechecked when its native task starts. Commands include quota/profile/Analytics refresh, saved inactive refresh, Add/Save/Switch/Forget/recovery/cancellation, account enable/order, graph preferences and native backup actions. Folder selection uses an asynchronous native folder panel. The adapter cannot implement credential operations.

The contract exposes Unix-second timestamps and JSON null for unavailable numeric/date values. Cards distinguish the dashboard-enabled flag from current sign-in. Passed resets remain derived assumptions with the original observed percentage/fetch time; the next reset stays unknown. Graphs distinguish saved/interpolated balances, predictions, observed/assumed/scheduled resets, stale readings and forecast constraints. Failed requests retain last successful data. Upstream error payloads are replaced by bounded generic messages; native Runway provides detailed native errors.

Bounds: the account selector includes the first 128 ordered accounts and explicitly reports truncation. Forecast calculations still use the full native account set. A graph returns the last 2,500 visible history points with a truncation notice and at most 2,500 prediction points / 512 reset events; its seven interval rows use the full native history. Analytics aggregates chart values in Swift across all selected saved archives before transport, preserving plan weighting and message/tool sums. Charts retain the top 24 categories per group and combine additional categories into Other; presentation shows top categories plus Other. Detail lists contain the top 100 chats and latest 100 periods, with account labels. Raw Analytics credit/review/group payloads are never exported. Missing account coverage is explicit.

History retains its native summary formatting, year heatmap, daily/weekly/cumulative modes, account filter and exact keyboard/hover values. Analytics has separate usage, tools and messages periods, usage feature/model/surface filters, messages model/surface filters, top chats, plan-limit windows/breakdowns and tool charts. Its time series leave missing-day gaps; charts describe totals as saved readings. Tab entry resets History/Analytics to All active accounts; a card's explicit History button selects that account.

## Switching and disconnects

Switch requires an explicit confirmation explaining that Codex will close and reopen. The native controller persists a receipt before accepting the request and returns an operation ID. An unstructured native task owns the transaction; loss of the iframe, stdio process or socket client cannot cancel it. The existing native preflight, current-session preservation, quit guards, replacement, verification, rollback, recovery and reopen code remains responsible. Cancellation is available only where the native store permits it, and is rejected after replacement begins. Recovery is explicit and also warns about the pending restart.

The last 32 operation receipts are persisted in native preferences, excluded from backups. Retrying a retained `requestID` returns its original operation, and different requests for the same running switch return that operation instead of starting another. Receipt IDs cannot be reused with different arguments. After a native process interruption, running receipts become Interrupted and the existing Keychain recovery journal remains authoritative. Completion can be queried after reopening Codex; inspect native recovery before retrying an interrupted or uncertain request. Nothing ever switches accounts because of a forecast or capacity warning.

## Development and validation

```zsh
(cd hub && npm ci --ignore-scripts && npm run build)
./scripts/test.sh
./scripts/test-hub.sh
python3 hub/server.py --http --fixture /private/tmp/runway-hub-fixture.json
```

The final command opens a read-only loopback preview at `http://127.0.0.1:43188`. The fixture is generated by the synthetic Swift checks and contains no real accounts or credentials. Without `--fixture`, preview reads the running bridge. **All preview mutations are disabled**, including switch and folder actions. Its HTTP server rejects foreign Hosts and never supports POST mutations. Browser-local presentation controls remain interactive for History/Analytics.

The original native suites cover status/automatic refresh, archive parsing, forecasts/DST/retention, hover behavior, profiles, scrolling, backups, and isolated login transaction guards. Additional checks cover DTO/Swift value parity, native preference/account reconciliation, no upstream calls on polling, unknown/stale/reset semantics, serialization, error retention, explicit field redaction, independent transaction ownership, duplicate switch requests, persisted receipts, socket permissions/lease/roundtrip, client disconnect after native admission (including SIGPIPE protection), MCP registration, argument validation and web presentation aggregation.

Verification on 2026-10-02: the plugin was registered, installed and reported enabled by the installed Codex CLI. The responsive fixture preview was inspected at 1280×800, 390×844 and a 520×620 embedded-layout preview; keyboard chart details and History modes worked. Actual sidebar rendering is **unverified**: this host's computer-use interface rejects inspection of the Codex app. Native app inspection also timed out. The signed bundle is staged in `dist`; the older installed/running Runway was not replaced or restarted. No real account switch or Codex restart was performed. Native-action fallback remains available. Retained local preview images and the validation receipt are under `/private/tmp/runway-hub-evidence`.


## UI review

The web presentation uses one vertical scroll owner in the embedded surface. Summary metrics span the top; account cards flow beside the forecast on wide screens and below it on narrow screens. More than four enabled accounts use a full-width card grid to avoid a long empty column. Cards have no capped height or private scroller. The forecast stays visible while scrolling taller desktop views. Graphs measure their actual container with ResizeObserver rather than stretching a guessed canvas width.

History follows native ProfileHeatmap: four blue daily intensity levels, bottom-filled weekly and cumulative bars, fixed-height cells, month labels, and exact hover/keyboard details. The current weekly bar stays visible through its future weekdays. Chart view, scale, and period controls share segmented styling; account and group filters have consistent labels. Analytics lists show five chats/periods initially and can expand across the page. Account enablement remains separate from current sign-in; native actions and forecasting are unchanged.

Reviewed saved native data in read-only browser previews at 1440×900, 390×844 and 520×620, plus a 128-account synthetic layout check. Retained screenshots and the review receipt are in `/private/tmp/runway-ui-review`. This is browser preview evidence; actual Codex host rendering was not captured in this review. Close and reopen the hub to load the rebuilt embedded assets. Runway does not need reinstalling for these web-only changes.
