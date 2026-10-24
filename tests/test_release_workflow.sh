#!/usr/bin/env bash
# Execute source, provenance, promotion and notification contracts without remote writes.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PYTHONDONTWRITEBYTECODE=1 python3 "${root}/tests/test_release_flow.py"
echo 'release workflow: PASS'
