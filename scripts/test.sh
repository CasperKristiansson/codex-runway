#!/bin/zsh
set -euo pipefail

build_dir="$(mktemp -d /private/tmp/codex-runway-checks.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

swiftc Sources/CodexRunway/Models.swift scripts/ForecastingChecks/main.swift -o "$build_dir/forecasting-checks"
"$build_dir/forecasting-checks"
