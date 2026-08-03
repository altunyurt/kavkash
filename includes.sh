#! /usr/bin/dash

# Data location follows the XDG spec; nothing configurable — the daemon and
# the shell integrations (bash/zsh source this file, fish mirrors it) can
# never disagree on paths.
KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"

KAV_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/kavkash"
mkdir -p "$KAV_RUNTIME_DIR" "$KAV_DATA_HOME"

KAV_SOCK_FILE="$KAV_RUNTIME_DIR/history.sock"
KAV_PID_FILE="$KAV_RUNTIME_DIR/server.pid"
KAV_DB_FILE="$KAV_DATA_HOME/history.db"

# Small shared helpers. kav_ prefix: this file is also sourced into
# interactive shells (functions.bash/.zsh), where plain names like `die`
# or `have` could clash with user-defined functions. install.sh keeps its
# own copies — it must run standalone before includes.sh is installed.
kav_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
kav_have() { command -v "$1" > /dev/null 2>&1; }
kav_say() { printf '%s\n' "$*"; }
kav_warn() { printf 'warning: %s\n' "$*" >&2; }

# kav_uuidv7 — RFC 9562 UUIDv7: 48-bit millisecond timestamp (lexicographic
# order == chronological order, so history sorts by id alone), version 7,
# variant 10, 72 random bits. hook.sh mints one per command; order matters
# for ORDER BY id DESC. Needs /dev/urandom (falls back to date+pid entropy).
kav_uuidv7() {
    ts=$(printf '%012x' "$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")")
    rand=$(od -An -N9 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')
    [ "${#rand}" -ge 18 ] || rand=$(printf '%06x%06x%06x' "$$" "$(date +%s)" "$$")
    # dash has no ${var:off:len}; cut does the same slicing
    printf '%s-%s-7%s-a%s-%s\n' \
        "$(printf '%s' "$ts" | cut -c1-8)" \
        "$(printf '%s' "$ts" | cut -c9-12)" \
        "$(printf '%s' "$rand" | cut -c1-3)" \
        "$(printf '%s' "$rand" | cut -c4-6)" \
        "$(printf '%s' "$rand" | cut -c7-18)"
}

# kav_uuidv7_decode ID — human-readable time from a UUIDv7 id (debug helper).
kav_uuidv7_decode() {
    hex_ts=$(printf '%s' "$1" | tr -d '-' | cut -c1-12)
    ms_ts=$((0x$hex_ts))
    date -d "@$((ms_ts / 1000))" +"%Y-%m-%d %H:%M:%S" 2> /dev/null || printf '%s\n' "$ms_ts"
}

