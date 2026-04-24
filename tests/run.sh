#!/bin/bash
# run.sh — Run all test-*.sh files, or specific files passed as args.
#
# Usage:
#   bash tests/run.sh                          # run all
#   bash tests/run.sh tests/test-update.sh     # run one file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

total_pass=0
total_fail=0
files=()
if [[ $# -gt 0 ]]; then
    files=("$@")
fi

if [[ ${#files[@]} -eq 0 ]]; then
    while IFS= read -r file; do
        files+=("$file")
    done < <(find tests -name 'test-*.sh' -type f | sort)
fi

for file in "${files[@]}"; do
    echo ""
    echo "=== $file ==="
    (
        source tests/test-lib.sh
        source "$file"
        run_tests
        print_summary
    )
    result=$?
    if [[ $result -ne 0 ]]; then
        total_fail=1
    fi
done

echo ""
if [[ $total_fail -ne 0 ]]; then
    echo "Some test files had failures."
    exit 1
else
    echo "All test files passed."
    exit 0
fi
