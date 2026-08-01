#!/bin/sh
# import.sh — import existing history (bash/zsh/fish + atuin) into kavkash DB.
#
# Runs standalone any time (install.sh invokes it when the user opts in) and
# is idempotent: commands already in the DB are skipped (match on text).
#
# Sources and their formats:
#   bash  ~/.bash_history            plain lines, or "#<epoch>" + line pairs
#                                    when HISTTIMEFORMAT was set
#   zsh   ${HISTFILE:-~/.zsh_history} plain lines, or extended ": <epoch>:<dur>;<cmd>"
#   fish  ${XDG_DATA_HOME}/fish/fish_history   YAML: "- cmd:", "  when:", "  paths:"
#   atuin ${XDG_DATA_HOME}/atuin/history.db    SQLite (history / history_v2)

set -eu

# Paths from includes.sh (same dir as this script).
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

DB="$KAV_DB_FILE"

kav_have sqlite3 || kav_die "sqlite3 required for history import"
kav_have base64 || kav_die "base64 required for history import"

# Ensure schema exists (same as server.sh) so import works before first run.
sqlite3 "$DB" << 'EOF'
CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    command TEXT NOT NULL,
    cwd TEXT NOT NULL,
    exit_code INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    timestamp INTEGER NOT NULL
);
EOF

tmpdir=${TMPDIR:-/tmp}
ENTRIES=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
SQLOUT=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT"' EXIT

now=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
counter=0

# emit <epoch_ms> <base64(cmd)> [base64(cwd)]
# Commands without a real timestamp get sequential values just below `now`,
# so un-timestamped files keep their original order (newest last = first Up).
emit() {
    counter=$((counter + 1))
    ts=$1
    b64=$2
    cwd=${3:-}
    [ -n "$b64" ] || return 0
    case "$ts" in '' | *[!0-9]*) ts=$((now - counter)) ;; esac
    printf '%s %s %s\n' "$ts" "$b64" "$cwd" >> "$ENTRIES"
}

b64() { printf '%s' "$1" | base64 -w0; }

import_bash() {
    f="${HISTFILE:-$HOME/.bash_history}"
    [ -f "$f" ] || return 0
    prev_ts=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*)
                prev_ts=${line#\#}
                case "$prev_ts" in *[!0-9]*) prev_ts="" ;; esac
                ;;
            *)
                [ -z "$line" ] && { prev_ts=""; continue; }
                emit "$prev_ts" "$(b64 "$line")"
                prev_ts=""
                ;;
        esac
    done < "$f"
}

import_zsh() {
    f="${HISTFILE:-$HOME/.zsh_history}"
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ": "*) # extended: ": <epoch>:<duration>;<command>"
                rest=${line#": "}
                ts=${rest%%:*}
                cmd=${rest#*:}
                cmd=${cmd#*;}
                ;;
            *)
                ts=""
                cmd=$line
                ;;
        esac
        [ -z "$cmd" ] && continue
        emit "$ts" "$(b64 "$cmd")"
    done < "$f"
}

import_fish() {
    f="${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history"
    [ -f "$f" ] || return 0
    ts=""
    cmd=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "- cmd: "*)
                [ -n "$cmd" ] && emit "$ts" "$(b64 "$cmd")"
                cmd=${line#"- cmd: "}
                ts=""
                ;;
            "  when: "*)
                ts=${line#"  when: "}
                case "$ts" in *[!0-9]*) ts="" ;; esac
                [ -n "$ts" ] && ts=$((ts * 1000)) # fish stores epoch seconds
                ;;
            "  paths:"*)
                : # ignore path lists
                ;;
        esac
    done < "$f"
    [ -n "$cmd" ] && emit "$ts" "$(b64 "$cmd")"
}

import_atuin() {
    f="${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db"
    [ -f "$f" ] || return 0
    # newer atuin uses history_v2, older uses history; both have timestamp/command/cwd.
    table=""
    for t in history_v2 history; do
        if sqlite3 "$f" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$t';" | grep -q 1; then
            table=$t
            break
        fi
    done
    [ -n "$table" ] || return 0
    # atuin timestamps are epoch ms; cwd may be NULL.
    sqlite3 -noheader "$f" "SELECT timestamp, COALESCE(cwd,''), command FROM $table;" \
        | while IFS='|' read -r ts cwd cmd || [ -n "$cmd" ]; do
            [ -z "$cmd" ] && continue
            emit "$ts" "$(b64 "$cmd")" "$(b64 "$cwd")"
        done
}

import_bash
import_zsh
import_fish
import_atuin

[ -s "$ENTRIES" ] || { echo "nothing to import (no history found)"; exit 0; }

# Bulk insert in a single sqlite3 session; NOT EXISTS skips duplicates.
while IFS=' ' read -r ts b64cmd b64cwd || [ -n "$b64cmd" ]; do
    cmd=$(printf '%s' "$b64cmd" | base64 -d 2> /dev/null || true)
    [ -z "$cmd" ] && continue
    safe=$(printf '%s' "$cmd" | sed "s/'/''/g")
    if [ -n "$b64cwd" ]; then
        cwd=$(printf '%s' "$b64cwd" | base64 -d 2> /dev/null || true)
        safe_cwd=$(printf '%s' "$cwd" | sed "s/'/''/g")
        printf "INSERT INTO history (command, cwd, exit_code, duration_ms, timestamp) SELECT '%s', '%s', 0, 0, %s WHERE NOT EXISTS (SELECT 1 FROM history WHERE command = '%s');\n" "$safe" "$safe_cwd" "$ts" "$safe" >> "$SQLOUT"
    else
        printf "INSERT INTO history (command, cwd, exit_code, duration_ms, timestamp) SELECT '%s', '', 0, 0, %s WHERE NOT EXISTS (SELECT 1 FROM history WHERE command = '%s');\n" "$safe" "$ts" "$safe" >> "$SQLOUT"
    fi
done < "$ENTRIES"

n_before=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
sqlite3 "$DB" < "$SQLOUT"
n_after=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
new=$((n_after - n_before))
printf 'imported %d new commands (duplicates skipped) into %s\n' "$new" "$DB"
