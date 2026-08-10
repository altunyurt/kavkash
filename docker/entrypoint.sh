#!/bin/sh
# kavkash demo container entrypoint.
#
# kavkash itself was installed at image build time (the documented
# `curl ... install.sh | dash` one-liner). This entrypoint:
#   1. imports whatever history files are mounted at the standard paths
#      (~/.bash_history, ~/.zsh_history, fish_history, atuin db) — so the
#      demo starts pre-seeded with YOUR commands, read from read-only
#      mounts (import.sh is idempotent, and picks up new host commands on
#      every start)
#   2. starts the daemon — with a TTY (docker run -it ...) it backgrounds
#      it and execs the requested shell; without one (docker run -d) it
#      runs the daemon in the foreground as PID 1 so the container stays
#      alive and shells attach via `docker exec -it` — the rc files baked
#      into the image wire the hooks, so every exec'd shell is a kavkash
#      session automatically.

set -eu

KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"
KAV_SOCK="${XDG_RUNTIME_DIR:-/tmp}/kavkash/history.sock"

"$KAV_DATA_HOME/import.sh" --all

wait_for_daemon() {
    i=0
    while [ "$i" -lt 100 ] && [ ! -S "$KAV_SOCK" ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if [ ! -S "$KAV_SOCK" ]; then
        echo "kavkash: daemon did not come up (see docker logs)" >&2
        exit 1
    fi
}

if [ -t 0 ] && [ $# -gt 0 ]; then
    # interactive (docker run -it ...): background daemon, then the shell
    "$KAV_DATA_HOME/server.sh" &
    wait_for_daemon
    exec "$@"
fi

# non-interactive (docker run -d / no command): daemon in the foreground
# as PID 1 — it keeps the container alive and cleans up socket+pid on
# docker stop (server.sh traps TERM).
exec "$KAV_DATA_HOME/server.sh"
