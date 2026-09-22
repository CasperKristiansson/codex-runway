#!/bin/zsh
set -euo pipefail

build_dir="$(mktemp -d /private/tmp/codex-runway-checks.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

swiftc -swift-version 6 -parse-as-library Sources/CodexRunway/ProfileModels.swift Sources/CodexRunway/Models.swift Sources/CodexRunway/CapacityDemand.swift Sources/CodexRunway/CapacityForecast.swift Sources/CodexRunway/ForecastJournal.swift Sources/CodexRunway/CodexAppServerClient.swift Sources/CodexRunway/RunwayStore.swift scripts/StatusChecks/main.swift -o "$build_dir/status-checks"
"$build_dir/status-checks"
swiftc -swift-version 6 -parse-as-library Sources/CodexRunway/ProfileModels.swift Sources/CodexRunway/Models.swift Sources/CodexRunway/CapacityDemand.swift Sources/CodexRunway/CapacityForecast.swift Sources/CodexRunway/ForecastJournal.swift Sources/CodexRunway/CapacityDisplayLayout.swift scripts/CapacityChecks/main.swift -o "$build_dir/capacity-checks"
"$build_dir/capacity-checks"
swiftc -swift-version 6 -parse-as-library Sources/CodexRunway/ProfileModels.swift scripts/ProfileChecks/main.swift -o "$build_dir/profile-checks"
"$build_dir/profile-checks"
swiftc -swift-version 6 -parse-as-library Sources/CodexRunway/RunwayScroller.swift scripts/ScrollerChecks/main.swift -o "$build_dir/scroller-checks"
"$build_dir/scroller-checks"
