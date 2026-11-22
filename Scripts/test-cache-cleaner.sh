#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d /private/tmp/mac-task-cache-fixture.XXXXXX)"
trap 'rm -r "$test_dir"' EXIT

swiftc \
    "$project_dir/Sources/MacTaskMonitor/CacheCleaner.swift" \
    "$project_dir/Sources/MacTaskMonitor/InstalledSoftwareScanner.swift" \
    "$project_dir/Sources/MacTaskMonitor/ProcessMonitor.swift" \
    "$project_dir/Tests/CacheCleanerChecks.swift" \
    -o "$test_dir/CacheCleanerChecks"
"$test_dir/CacheCleanerChecks"
