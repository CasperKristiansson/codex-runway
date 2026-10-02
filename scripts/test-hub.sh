#!/bin/zsh
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"
build_dir="$(mktemp -d /private/tmp/runway-hub-checks.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
sources=(ProfileModels Models CapacityDemand CapacityForecast ForecastJournal AnalyticsModels AnalyticsArchiveStore AnalyticsClient CodexAppServerClient SavedLoginStore CodexAuthFile CodexLoginSwitcher CodexDesktopLifecycle LoginRecoveryStore CodexAccountOnboarding RunwayDisplayPreferences RunwayStore RunwayBackupStore RunwayBackupManager HubSnapshot RunwayHubController RunwayHubSocket)
files=()
for source in $sources; do files+=("Sources/CodexRunway/$source.swift"); done
swiftc -swift-version 6 -parse-as-library $files scripts/BridgeChecks/main.swift -o "$build_dir/bridge-checks"
"$build_dir/bridge-checks" "${1:-/private/tmp/runway-hub-fixture.json}"
(cd hub && npm test)
