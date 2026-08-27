#!/bin/sh
# kavkash installer — fetches the latest stable release from GitHub and
# installs it into ${XDG_DATA_HOME:-~/.local/share}/kavkash.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | sh
#
# Overrides:
#   KAVKASH_REPO=owner/repo     repository (default: altunyurt/kavkash)
#   KAVKASH_BRANCH=branch       fallback branch when no stable release exists
#   KAVKASH_TARBALL_URL=url     skip release resolution, download this tarball
#   KAVKASH_TARBALL_SHA256=x    expected sha256 of KAVKASH_TARBALL_URL
#   KAVKASH_SKIP_VERIFY=1       proceed even if no checksum could be verified
#   KAVKASH_NO_SYSTEMD=1        skip systemd --user unit creation/activation
#   KAVKASH_IMPORT=1|0          import existing shell/atuin history
#                               (default: prompt interactively)
#
# Writes ${KAV_DATA_HOME}/INSTALLED_REVISION: repo, tag, commit SHA,
# tarball sha256, verification status, timestamp — read it to know
# exactly what is on disk (do not trust a tag name alone; tags move).
#
# systemd --user integration: a `kavkash.service` unit (Restart=on-abnormal,
# started at login) where systemd has a reachable user session; otherwise
# manual start instructions. The unit file is regenerated on every run —
# local customizations go in a drop-in (`systemctl --user edit`).
#
# Safety: all executable logic lives inside main(), invoked only on the
# final line — a POSIX shell parses the whole file before running
# anything, so a truncated `curl | sh` download exits at parse time
# without side effects. Keep it that way.

set -eu

say() { printf '%s\n' "$*"; }
warn() { say "warning: $*" >&2; }
die() {
    say "error: $*" >&2
    exit 1
}

have() { command -v "$1" > /dev/null 2>&1; }

# sha256 tool varies by platform
sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif have openssl; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        echo ""
    fi
}

# tiny JSON string-field extractor: field name -> value (best-effort, no deps)
json_field() {
    # $1 = field name, reads json from stdin
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

http_get() {
    # $1 = url, prints body to stdout, empty on failure (never fatal on its own)
    if have curl; then
        curl -fsSL --max-time 15 "$1" 2> /dev/null || true
    else
        wget -qO- "$1" 2> /dev/null || true
    fi
}

download() {
    # $1 = url, $2 = dest path
    if have curl; then
        curl -fsSL --max-time 60 "$1" -o "$2" || die "download failed: $1"
    else
        wget -qO "$2" "$1" || die "download failed: $1"
    fi
}

resolve_source() {
    # Sets: url, tag, resolved_sha, expected_sha (globals, set -u safe since
    # all are assigned unconditionally in every branch below)
    if [ -n "${KAVKASH_TARBALL_URL:-}" ]; then
        url="$KAVKASH_TARBALL_URL"
        tag="(custom tarball)"
        resolved_sha="(unknown — custom tarball, not resolved via GitHub API)"
        if [ -n "${KAVKASH_TARBALL_SHA256:-}" ]; then
            expected_sha="$KAVKASH_TARBALL_SHA256"
        else
            expected_sha=""
            warn "KAVKASH_TARBALL_URL set without KAVKASH_TARBALL_SHA256 — the" \
                "download cannot be verified. Set KAVKASH_TARBALL_SHA256 or pass" \
                "KAVKASH_SKIP_VERIFY=1 to proceed anyway."
        fi
        say "kavkash: fetching custom tarball $url"
        return 0
    fi

    expected_sha=""
    api_tag_json=$(http_get "https://api.github.com/repos/$KAVKASH_REPO/releases/latest")
    tag=$(printf '%s' "$api_tag_json" | json_field tag_name)
    resolved_sha=""

    if [ -n "$tag" ]; then
        # Resolve the tag to an immutable commit SHA (tags can be moved).
        ref_json=$(http_get "https://api.github.com/repos/$KAVKASH_REPO/git/refs/tags/$tag")
        obj_sha=$(printf '%s' "$ref_json" | json_field sha)
        obj_type=$(printf '%s' "$ref_json" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
        if [ "$obj_type" = "tag" ] && [ -n "$obj_sha" ]; then
            # annotated tag object — dereference to the commit it points at
            tag_obj_json=$(http_get "https://api.github.com/repos/$KAVKASH_REPO/git/tags/$obj_sha")
            resolved_sha=$(printf '%s' "$tag_obj_json" | json_field sha)
        else
            resolved_sha="$obj_sha"
        fi
    fi

    if [ -n "$tag" ]; then
        # Prefer the published release asset (verifiable against
        # SHA256SUMS); fall back to GitHub's auto-generated archive.
        asset_url=$(printf '%s' "$api_tag_json" \
            | tr ',' '\n' \
            | grep '"browser_download_url"' \
            | grep 'kavkash-.*\.tar\.gz' \
            | json_field browser_download_url)
        if [ -n "$asset_url" ]; then
            url="$asset_url"
            say "kavkash: fetching release asset '$tag'"
        elif [ -n "$resolved_sha" ]; then
            url="https://github.com/$KAVKASH_REPO/archive/$resolved_sha.tar.gz"
            say "kavkash: fetching release '$tag' (commit $resolved_sha)"
        else
            # got a tag name but couldn't resolve a SHA — install by tag
            # name; less verifiable but still a named release
            url="https://github.com/$KAVKASH_REPO/archive/refs/tags/$tag.tar.gz"
            resolved_sha="(unresolved — GitHub API did not return a commit SHA for this tag)"
            warn "could not resolve tag '$tag' to a commit SHA; installing by tag name only"
            say "kavkash: fetching release '$tag'"
        fi
    else
        # No stable release — fall back to branch HEAD (a moving target).
        url="https://github.com/$KAVKASH_REPO/archive/refs/heads/$KAVKASH_BRANCH.tar.gz"
        tag="(none — no stable release found)"
        resolved_sha="(unresolved — installed from moving branch HEAD, not a pinned commit)"
        warn "no stable release found for $KAVKASH_REPO; falling back to branch" \
            "'$KAVKASH_BRANCH'. This is a moving target — re-running this" \
            "installer later may install different code even with an" \
            "unchanged install.sh."
        say "kavkash: fetching branch '$KAVKASH_BRANCH'"
    fi

    # Best-effort: a published checksum asset (GitHub doesn't generate
    # these itself).
    if [ -n "${api_tag_json:-}" ]; then
        for name in SHA256SUMS SHA256SUMS.txt checksums.txt sha256sums.txt; do
            asset_url=$(printf '%s' "$api_tag_json" \
                | tr ',' '\n' \
                | grep "\"browser_download_url\"" \
                | grep "$name" \
                | json_field browser_download_url)
            [ -n "$asset_url" ] || continue
            sums=$(http_get "$asset_url")
            [ -n "$sums" ] || continue
            candidate=$(printf '%s' "$sums" | grep -i "$(basename "$url" 2> /dev/null || true)" | awk '{print $1}' | head -n 1)
            if [ -n "$candidate" ]; then
                expected_sha="$candidate"
                break
            fi
        done
    fi
}

fetch_and_verify() {
    # Sets: tmpdir, tarball, actual_sha, verified
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kavkash.XXXXXX")
    trap 'rm -rf "$tmpdir"' EXIT INT TERM HUP

    tarball="$tmpdir/kavkash.tar.gz"
    download "$url" "$tarball"

    verified="no"
    actual_sha=$(sha256_of "$tarball")
    if [ -z "$actual_sha" ]; then
        warn "no sha256 tool found (sha256sum/shasum/openssl) — cannot compute" \
            "a checksum for this download at all"
    elif [ -n "$expected_sha" ]; then
        if [ "$actual_sha" = "$expected_sha" ]; then
            verified="yes"
            say "kavkash: checksum verified ($actual_sha)"
        else
            die "checksum mismatch: expected $expected_sha, got $actual_sha — refusing to install"
        fi
    else
        warn "downloaded tarball sha256 is $actual_sha but no expected checksum" \
            "was available to verify it against (upstream did not publish one" \
            "for this ref). Recorded, but NOT verified."
        if [ "$KAVKASH_SKIP_VERIFY" != "1" ] && [ -n "${KAVKASH_TARBALL_URL:-}" ]; then
            die "refusing to install an unverified custom tarball without" \
                "KAVKASH_TARBALL_SHA256 or KAVKASH_SKIP_VERIFY=1"
        fi
    fi
}

unpack() {
    # Sets: src
    tar -xzf "$tarball" -C "$tmpdir" || die "could not unpack tarball"

    # the tarball has a single top-level directory; locate it (POSIX-safe)
    cd "$tmpdir"
    src=""
    for d in */; do
        [ -d "$d" ] && {
            src="$tmpdir/$d"
            break
        }
    done
    [ -n "$src" ] || die "unexpected tarball layout"
}

install_files() {
    install -d "$KAV_DATA_HOME"

    for f in includes.sh hook.sh server.sh processor.sh query.sh picker.sh delete.sh import.sh backup.sh kavkash functions.bash functions.fish functions.zsh; do
        install -m 755 "$src/$f" "$KAV_DATA_HOME/$f"
    done

    [ -f "$src/LICENSE" ] && install -m 644 "$src/LICENSE" "$KAV_DATA_HOME/LICENSE"
    [ -f "$src/README.md" ] && install -m 644 "$src/README.md" "$KAV_DATA_HOME/README.md"
    [ -f "$src/VERSION" ] && install -m 644 "$src/VERSION" "$KAV_DATA_HOME/VERSION"
}

# --- runtime dependency check ---------------------------------------------

_dep() {
    # _dep NAME MESSAGE — one line of the dependency report; warns on missing
    _d_name=$1
    _d_msg=$2
    if have "$_d_name"; then
        printf '  %-9s %s\n' "$_d_name" "OK"
    else
        printf '  %-9s %s\n' "$_d_name" "MISSING"
        warn "missing dependency: $_d_name — $_d_msg"
    fi
}

check_deps() {
    # Runtime deps (what kavkash needs to run, not the installer's own).
    # Warnings only — install never blocks. sqlite3/awk/base64/dash/socat
    # are required; fzf gates only the picker.
    say "dependency check:"
    _dep sqlite3 "required — storage; the daemon cannot run without it"
    _dep awk "required — netstring/query parsing in the daemon"
    _dep base64 "required — netstring field decoding in the daemon"
    _dep dash "required — all helper scripts run under #!/usr/bin/dash"
    if have socat; then
        printf '  %-9s %s\n' socat "OK"
    else
        printf '  %-9s %s\n' socat "MISSING"
        warn "missing dependency: socat — the daemon cannot receive commands or serve history (required; install socat)"
    fi
    if have fzf; then
        fzf_ver=$(fzf --version 2> /dev/null | awk 'NR == 1 { print $1 }')
        if [ -n "$fzf_ver" ] && printf '%s\n' "$fzf_ver" | awk -F. 'NR == 1 { exit ($1 > 0 || $2 >= 54) ? 0 : 1 }'; then
            printf '  %-9s %s\n' fzf "OK ($fzf_ver)"
        else
            printf '  %-9s %s\n' fzf "MISSING"
            warn "missing dependency: fzf — found ${fzf_ver:-none}, needs >= 0.54; the picker and Up/Down stepping stay disabled (history is still recorded)"
        fi
    else
        printf '  %-9s %s\n' fzf "MISSING"
        warn "missing dependency: fzf — no picker or Up/Down stepping (history is still recorded)"
    fi
    say ""
}

# --- systemd --user integration --------------------------------------------

systemd_usable() {
    # systemd as PID 1, systemctl present, AND a reachable --user bus —
    # the binary alone doesn't mean a user session exists (containers,
    # chroots, WSL1, non-systemd distros with a systemctl shim).
    [ "${KAVKASH_NO_SYSTEMD:-0}" != "1" ] || return 1
    [ -d /run/systemd/system ] || return 1
    have systemctl || return 1
    systemctl --user show-environment > /dev/null 2>&1 || return 1
    return 0
}

write_systemd_unit() {
    install -d "$SYSTEMD_USER_DIR"
    cat > "$SYSTEMD_USER_DIR/kavkash.service" << EOF
# Generated by the kavkash installer — do not hand-edit this file directly,
# it is regenerated on every install/update. For local customizations use:
#   systemctl --user edit kavkash.service
[Unit]
Description=kavkash background daemon
After=default.target

[Service]
Type=simple
ExecStart=$KAV_DATA_HOME/server.sh
# KillMode=mixed: TERM goes to server.sh only, so its shutdown drain
# (in-flight preexec writes before the socat listener dies) gets a
# chance; remaining processes are KILLed after TimeoutStopSec. The
# default control-group mode TERMs socat in the same instant and loses
# the very command that stopped the daemon.
KillMode=mixed
# Restart=on-abnormal: retry on crashes (signals), never on clean exits —
# server.sh exits 0 when a daemon is already running, so a foreign/stale
# daemon must not drive a restart loop.
Restart=on-abnormal
RestartSec=2

[Install]
WantedBy=default.target
EOF
    say "systemd: wrote $SYSTEMD_USER_DIR/kavkash.service"
}

enable_systemd_service() {
    # Sets: systemd_enabled ("yes"/"no")
    systemd_enabled="no"
    if systemctl --user daemon-reload > /dev/null 2>&1 \
        && systemctl --user enable --now kavkash.service > /dev/null 2>&1; then
        systemd_enabled="yes"
        say "systemd: enabled and started kavkash.service"
    else
        warn "systemd: could not enable/start kavkash.service (unit was still" \
            "written to $SYSTEMD_USER_DIR/kavkash.service). You can retry" \
            "manually with: systemctl --user enable --now kavkash.service"
    fi

    # Without lingering enabled, a --user service stops when the last login
    # session ends. Not fatal — just tell the user, since it's an easy trap.
    if have loginctl; then
        linger_state=$(loginctl show-user "$(id -un)" -p Linger --value 2> /dev/null || echo "")
        if [ "$linger_state" != "yes" ]; then
            warn "systemd: lingering is not enabled for this user, so" \
                "kavkash.service will stop when you log out of every" \
                "session. Enable it with: loginctl enable-linger $(id -un)"
        fi
    fi
}

setup_systemd() {
    # Sets: systemd_enabled ("yes"/"no"/"skipped")
    if ! systemd_usable; then
        systemd_enabled="skipped"
        return 0
    fi
    write_systemd_unit
    enable_systemd_service
}

import_history() {
    # KAVKASH_IMPORT=1/0, else prompt. Under curl|sh, stdin is the script
    # pipe, not a terminal — read the answer from /dev/tty.
    if [ "${KAVKASH_IMPORT:-}" = "1" ]; then
        answer="y"
    elif [ "${KAVKASH_IMPORT:-}" = "0" ]; then
        answer="n"
    elif { printf "import existing shell/atuin history into kavkash? [y/N] " > /dev/tty \
        && read answer < /dev/tty; } 2> /dev/null; then
        { printf '\r' > /dev/tty; } 2> /dev/null || true
    elif [ -t 0 ]; then
        printf "import existing shell/atuin history into kavkash? [y/N] "
        read answer || answer="n"
    else
        answer="n"
    fi
    case "$answer" in
        y | Y) answer="y" ;;
        *) answer="n" ;;
    esac

    if [ "$answer" = "y" ]; then
        say "kavkash: importing history..."
        "$KAV_DATA_HOME/import.sh" --all || warn "history import failed (see error above)"
    fi
}

record_revision() {
    cat > "$KAV_DATA_HOME/INSTALLED_REVISION" << EOF
repo=$KAVKASH_REPO
version=$(cat "$src/VERSION" 2> /dev/null || echo unknown)
ref=$tag
commit_sha=$resolved_sha
tarball_url=$url
tarball_sha256=${actual_sha:-unknown}
checksum_verified=$verified
systemd_service_enabled=$systemd_enabled
installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || echo unknown)
EOF
}

print_summary() {
    say ""
    say "installed to: $KAV_DATA_HOME"
    say "version:      $(cat "$KAV_DATA_HOME/VERSION" 2> /dev/null || echo unknown)"
    say "revision:     $KAV_DATA_HOME/INSTALLED_REVISION"
    if [ "$verified" != "yes" ] && [ "$verified" != "local" ]; then
        say "              (checksum NOT verified against an upstream-published value —"
        say "               see INSTALLED_REVISION for the tarball_sha256 that was installed)"
    fi
    say ""
    say "next steps:"

    say "  kavkash status   — daemon, version, and history overview (try it!)"
    say "  kavkash backup   — snapshot your history (recommended now)"
    say "  kavkash history  — history data: prune, dedup, stats, compact, import"
    say '  kavkash help     — every subcommand; kavkash CMD --help for details'

    say "  1. start the daemon:"
    if [ "$systemd_enabled" = "yes" ]; then
        say "       running under systemd --user (kavkash.service)"
        say "       status:  systemctl --user status kavkash.service"
        say "       logs:    journalctl --user -u kavkash.service -f"
        say "       restart: systemctl --user restart kavkash.service"
    elif [ "$systemd_enabled" = "no" ]; then
        say "       unit installed but not enabled — start it with:"
        say "       systemctl --user enable --now kavkash.service"
        say "       or run it directly, without systemd:"
        say "       $KAV_DATA_HOME/server.sh &"
    else
        say "       $KAV_DATA_HOME/server.sh &"
        say "       (systemd --user isn't available on this system, so this is manual)"
    fi

    say "  2. hook your shell — add ONE line to your rc file, then start a new shell:"
    say "       bash:  source $KAV_DATA_HOME/functions.bash"
    say "       zsh:   source $KAV_DATA_HOME/functions.zsh"
    say "       fish:  source $KAV_DATA_HOME/functions.fish"

    detected=$(basename "${SHELL:-}")
    case "$detected" in
        bash)
            say "       your shell is bash — add it now:"
            say "       echo 'source $KAV_DATA_HOME/functions.bash' >> ~/.bashrc"
            ;;
        zsh)
            say "       your shell is zsh — add it now:"
            say "       echo 'source $KAV_DATA_HOME/functions.zsh' >> ~/.zshrc"
            ;;
        fish)
            say "       your shell is fish — add it now:"
            say "       echo 'source $KAV_DATA_HOME/functions.fish' >> ~/.config/fish/config.fish"
            ;;
    esac

    say "  3. existing history (bash/zsh/fish files, atuin DB):"
    say "       import now, or any time later (idempotent — safe to re-run):"
    say "       kavkash history import --all"
    say "       re-running this installer also offers the import again"

    say "  4. start from scratch (clear all stored history):"
    say "       rm -f $KAV_DATA_HOME/history.db"
    say "       (the daemon recreates the database on its next start)"

    if [ "$systemd_enabled" != "yes" ]; then
        pidfile="${XDG_RUNTIME_DIR:-/tmp}/kavkash/server.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2> /dev/null; then
            say ""
            say "note: a kavkash daemon is running (pid $(cat "$pidfile")) — restart it to pick up the update"
        fi
    fi
}

main() {
    KAVKASH_REPO="${KAVKASH_REPO:-altunyurt/kavkash}"
    KAVKASH_BRANCH="${KAVKASH_BRANCH:-main}"
    KAVKASH_SKIP_VERIFY="${KAVKASH_SKIP_VERIFY:-0}"
    KAVKASH_NO_SYSTEMD="${KAVKASH_NO_SYSTEMD:-0}"
    KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"
    SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

    # Local clone mode: run from a git checkout → install from the
    # working tree instead of GitHub (KAVKASH_FORCE_REMOTE=1 overrides).
    SCRIPT_DIR=$(cd "$(dirname -- "$0")" 2> /dev/null && pwd 2> /dev/null || true)
    if [ -z "${KAVKASH_FORCE_REMOTE:-}" ] && [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/.git" ]; then
        say "local git checkout detected — installing from $SCRIPT_DIR"
        say "(not from GitHub; KAVKASH_FORCE_REMOTE=1 forces the remote flow)"
        src="$SCRIPT_DIR"
        verified="local"
        tag="local working tree"
        resolved_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2> /dev/null || echo unknown)
        url="local clone: $SCRIPT_DIR"
    else
        have curl || have wget || die "need curl or wget to download kavkash"
        have tar || die "need tar to unpack kavkash"
        resolve_source
        fetch_and_verify
        unpack
    fi

    install_files

    # ~/.local/bin/kavkash is a symlink to the install dir, so the
    # dispatcher's realpath resolves its home.
    if [ -n "${KAVKASH_NO_SYMLINK:-}" ]; then
        say "skipping ~/.local/bin/kavkash symlink (KAVKASH_NO_SYMLINK set)"
    else
        install -d "$HOME/.local/bin"
        ln -sfn "$KAV_DATA_HOME/kavkash" "$HOME/.local/bin/kavkash"
    fi

    check_deps
    import_history
    setup_systemd
    record_revision
    print_summary
}

# Everything above this line is only function/variable definitions and is
# inert on its own. This is the single point where the script actually does
# anything — if the file were truncated before this line, execution stops
# here with nothing having happened.
main "$@"
