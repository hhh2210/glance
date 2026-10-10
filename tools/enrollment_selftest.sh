#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/glance-enrollment.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

swiftc -O -parse-as-library \
  "$repo_root/glance/Onboarding/EnrollmentCaptureState.swift" \
  "$repo_root/tools/enrollment_selftest.swift" \
  -o "$test_dir/enrollment_selftest"
"$test_dir/enrollment_selftest"
