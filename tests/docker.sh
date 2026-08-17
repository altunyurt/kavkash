#!/bin/sh
# tests/docker.sh [FILTER] — build the test image and run the suite
# inside it. The repo is mounted read-only, so no rebuilds while
# iterating; the same tests/run.sh works natively on the host.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

docker build -q -f "$DIR/tests/Dockerfile" -t kavkash-test "$DIR" > /dev/null
exec docker run --rm -v "$DIR:/app:ro" kavkash-test /app/tests/run.sh "$@"
