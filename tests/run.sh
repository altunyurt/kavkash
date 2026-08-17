#!/bin/sh
# tests/run.sh [FILTER] — run every t-*.sh in its own process (each
# creates its own sandbox). Exit nonzero if any file fails.
TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
filter="${1:-}"

files=0
failed=0
for f in "$TESTS_DIR"/t-*.sh; do
    name=$(basename "$f")
    case "$name" in *"$filter"*) ;; *) continue ;; esac
    files=$((files + 1))
    echo "--- $name ---"
    if "$f"; then
        echo "ok: $name"
    else
        echo "FAILED: $name"
        failed=$((failed + 1))
    fi
done

echo "== $((files - failed))/$files test files passed =="
[ "$failed" -eq 0 ]
