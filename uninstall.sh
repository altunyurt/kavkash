#!/bin/sh
# kavkash uninstaller — removes a kavkash installation: the daemon
# (systemd --user unit, else the pid-file daemon), runtime artifacts
# (socket, pid file, server log), the unit file, and the install dir
# ${XDG_DATA_HOME:-~/.local/share}/kavkash (history.db kept unless
# --purge).
#
# It never touches shell rc files — the installer only ever PRINTED the
# `source .../functions.*` line, so this just prints the lines to remove.
#
# Usage:
#   ./uninstall.sh            interactive — confirms before removing anything
#   ./uninstall.sh -y         non-interactive — same as interactive defaults
#   ./uninstall.sh -y --purge non-interactive — also delete stored history
#
# Overrides:
#   KAVKASH_NO_SYSTEMD=1      skip the systemd unit removal entirely
#   KAVKASH_KEEP_DB=1|0       decide history.db fate without prompting
#   KAVKASH_ASSUME_YES=1      same as -y
#
# Safety: same layout as install.sh — all executable logic lives inside
# main(), invoked only on the final line, so a truncated download can
# never partially uninstall anything.

set -eu

say() { printf '%s\n' "$*"; }
warn() { say "warning: $*" >&2; }
die() {
    say "error: $*" >&2
    exit 1
}

have() { command -v "$1" > /dev/null 2>&1; }

# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------

ASSUME_YES=0
PURGE=0
KEEP_DB_UNSET=1

for arg in "$@"; do
    case "$arg" in
        -y | --yes | -f | --force)
            ASSUME_YES=1
            ;;
        --purge | --delete-db)
            PURGE=1
            ;;
        -h | --help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $arg (see $0 --help)"
            ;;
    esac
done

[ "${KAVKASH_ASSUME_YES:-0}" = "1" ] && ASSUME_YES=1

# --------------------------------------------------------------------------
# paths (kept in sync with includes.sh; install.sh keeps its own copies too)
# --------------------------------------------------------------------------

KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"
KAV_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/kavkash"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
KAV_SOCK_FILE="$KAV_RUNTIME_DIR/history.sock"
KAV_PID_FILE="$KAV_RUNTIME_DIR/server.pid"

# --------------------------------------------------------------------------
# confirmation
# --------------------------------------------------------------------------

confirm() {
    # $1 = question, $2 = default (y/n). Exits non-zero if refused.
    [ "$ASSUME_YES" = "1" ] && return 0
    answer=""
    if { printf '%s [%s] ' "$1" "$2" > /dev/tty && read answer < /dev/tty; } 2> /dev/null; then
        :
    elif [ -t 0 ]; then
        printf '%s [%s] ' "$1" "$2"
        read answer || answer="$2"
    else
        answer="$2"
    fi
    case "$answer" in
        y | Y) return 0 ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# daemon shutdown
# --------------------------------------------------------------------------

# pid_in_kavkash PID — true only if the pid currently belongs to a kavkash
# daemon process (server.sh or its socat). Matches the cmdline, not just the
# comm name ("dash" alone would match any dash process), so a stale pid file
# that got recycled to an unrelated process is left alone.
pid_in_kavkash() {
    [ -n "${1:-}" ] || return 1
    [ -d "/proc/$1" ] || return 1
    tr '\0' ' ' < "/proc/$1/cmdline" 2> /dev/null | grep -q 'server\.sh\|kavkash' || return 1
    return 0
}

stop_systemd_unit() {
    [ "${KAVKASH_NO_SYSTEMD:-0}" != "1" ] || return 0
    [ -f "$SYSTEMD_USER_DIR/kavkash.service" ] || return 0
    have systemctl || return 0

    say "stopping kavkash.service"
    systemctl --user stop kavkash.service > /dev/null 2>&1 || true
    systemctl --user disable kavkash.service > /dev/null 2>&1 || true
}

stop_pidfile_daemon() {
    [ -f "$KAV_PID_FILE" ] || return 0
    pid=$(cat "$KAV_PID_FILE" 2> /dev/null || true)
    [ -n "$pid" ] || return 0

    if pid_in_kavkash "$pid"; then
        say "stopping manual daemon (pid $pid)"
        kill -TERM "$pid" 2> /dev/null || true
        # give the EXIT trap (socket/pid cleanup) a moment to run
        i=0
        while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 20 ]; do
            sleep 0.1
            i=$((i + 1))
        done
    else
        warn "pid file $KAV_PID_FILE holds pid $pid, which is not a kavkash" \
            "process — leaving it alone"
    fi
}

# --------------------------------------------------------------------------
# file removal
# --------------------------------------------------------------------------

remove_runtime_artifacts() {
    rm -f "$KAV_SOCK_FILE" "$KAV_PID_FILE" "$KAV_RUNTIME_DIR/server.log"
    rm -f "$HOME/.local/bin/kavkash"
    # runtime dir is ours (created by includes.sh) — remove when empty
    rmdir "$KAV_RUNTIME_DIR" 2> /dev/null || true
}

remove_systemd_unit() {
    [ "${KAVKASH_NO_SYSTEMD:-0}" != "1" ] || return 0
    [ -f "$SYSTEMD_USER_DIR/kavkash.service" ] || return 0

    rm -f "$SYSTEMD_USER_DIR/kavkash.service"
    say "removed $SYSTEMD_USER_DIR/kavkash.service"
    have systemctl && systemctl --user daemon-reload > /dev/null 2>&1 || true
}

remove_data_home() {
    [ -d "$KAV_DATA_HOME" ] || return 0

    # A directory containing .git is a working copy (someone copied the repo
    # there by hand, like `cp -r` or `git clone`), not an install.sh output.
    # rm -rf'ing a clone could destroy uncommitted work — refuse and punt.
    if [ -d "$KAV_DATA_HOME/.git" ]; then
        warn "$KAV_DATA_HOME looks like a git checkout (contains .git), not an" \
            "install.sh-installed directory — leaving it untouched"
        warn "remove it manually if you really want it gone:"
        warn "  rm -rf $KAV_DATA_HOME"
        return 0
    fi

    # history.db: keep by default (it IS your history). Only --purge or an
    # explicit KAVKASH_KEEP_DB=0 deletes it. Under -y (ASSUME_YES) the
    # question is skipped and the default (keep) applies — confirm() would
    # otherwise answer "yes" to the prompt.
    keep_db=1
    if [ -n "${KAVKASH_KEEP_DB:-}" ]; then
        [ "$KAVKASH_KEEP_DB" = "1" ] || keep_db=0
    elif [ "$PURGE" = "1" ]; then
        keep_db=0
    elif [ "$ASSUME_YES" != "1" ] \
        && confirm "delete stored history too? (keeps $KAV_DATA_HOME/history.db otherwise)" n; then
        keep_db=0
    fi

    if [ "$keep_db" = "1" ] && [ -f "$KAV_DATA_HOME/history.db" ]; then
        say "keeping $KAV_DATA_HOME/history.db"
        find "$KAV_DATA_HOME" -mindepth 1 ! -name 'history.db' -delete 2> /dev/null || true
        rmdir "$KAV_DATA_HOME" 2> /dev/null || true
    else
        if [ "$keep_db" = "0" ] && [ -f "$KAV_DATA_HOME/history.db" ]; then
            say "deleting stored history"
        fi
        rm -rf "$KAV_DATA_HOME"
    fi
}

print_remaining_steps() {
    say ""
    say "kavkash removed. Remaining, if you added them manually:"
    say "  shell hooks — remove the source line from your rc file(s):"
    say "    bash:  remove 'source $KAV_DATA_HOME/functions.bash' from ~/.bashrc"
    say "    zsh:   remove 'source $KAV_DATA_HOME/functions.zsh' from ~/.zshrc"
    say "    fish:  remove 'source $KAV_DATA_HOME/functions.fish' from ~/.config/fish/config.fish"
    if [ -d "$KAV_DATA_HOME" ]; then
        say "  install dir kept (history.db): $KAV_DATA_HOME"
        say "    to delete it for good: rm -rf $KAV_DATA_HOME"
    fi
}

main() {
    # Before touching anything, make sure we are uninstalling the intended
    # thing. If neither the unit file nor the install dir nor runtime files
    # exist, there is nothing to do.
    if [ ! -f "$SYSTEMD_USER_DIR/kavkash.service" ] \
        && [ ! -d "$KAV_DATA_HOME" ] \
        && [ ! -e "$KAV_PID_FILE" ] && [ ! -e "$KAV_SOCK_FILE" ]; then
        say "nothing to uninstall (no unit file, install dir, or runtime files found)"
        return 0
    fi

    say "kavkash uninstaller"
    say "  install dir:   $KAV_DATA_HOME"
    say "  runtime dir:   $KAV_RUNTIME_DIR"
    say "  systemd unit:  $SYSTEMD_USER_DIR/kavkash.service"
    confirm "proceed with uninstall?" y || {
        say "aborted."
        return 1
    }

    stop_systemd_unit
    stop_pidfile_daemon
    remove_runtime_artifacts
    remove_systemd_unit
    remove_data_home
    print_remaining_steps
}

# All functions above are inert on their own; this is the single point where
# anything happens (same safety pattern as install.sh).
main "$@"
