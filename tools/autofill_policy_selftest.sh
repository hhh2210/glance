#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/glance-autofill-policy.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

swiftc -O -parse-as-library \
  "$repo_root/glance/AutoFillPromptPolicy.swift" \
  "$repo_root/tools/autofill_policy_selftest.swift" \
  -o "$test_dir/autofill_policy_selftest"
"$test_dir/autofill_policy_selftest"
