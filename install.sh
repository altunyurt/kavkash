#!/bin/sh
# kavkash installer — fetches the latest stable release from GitHub and
# installs it into ${XDG_DATA_HOME:-~/.local/share}/kavkash.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | sh
#
# Runs under any POSIX shell (dash, bash, ...). Overrides:
#   KAVKASH_REPO=owner/repo   repository to install from (default: altunyurt/kavkash)
#   KAVKASH_BRANCH=branch     fallback branch when no stable release exists
#   KAVKASH_TARBALL_URL=url   skip release resolution, download this tarball
#   KAVKASH_TARBALL_SHA256=x  expected sha256 of KAVKASH_TARBALL_URL (recommended
#                             whenever KAVKASH_TARBALL_URL is set — see note below)
#   KAVKASH_SKIP_VERIFY=1     proceed even if no checksum could be verified
#   KAVKASH_NO_SYSTEMD=1      skip systemd --user unit creation/activation entirely
#   KAVKASH_IMPORT=1|0        import existing shell/atuin history: 1 = yes,
#                             0 = no (default: prompt interactively)
#
# Revision tracking:
#   On success this script writes ${KAV_DATA_HOME}/INSTALLED_REVISION containing
#   the repo, the resolved tag, the resolved commit SHA (immutable), the
#   sha256 of the downloaded tarball, whether that checksum was verified
#   against a value published by upstream, and the install timestamp. Read
#   that file any time to know exactly what is on disk and how it was
#   verified — do not trust a tag name alone, since tags are mutable.
#
# systemd --user integration:
#   On systems running systemd with a reachable user session, this script
#   installs a `kavkash.service` user unit (Restart=on-failure, started at
#   login via default.target) instead of asking you to background the
#   daemon manually. Where systemd isn't usable — no systemd PID 1, no
#   `systemctl`, or no active --user session/bus (e.g. a container without
#   lingering enabled) — it falls back to printing manual start
#   instructions. Local customizations belong in a
#   drop-in (`systemctl --user edit kavkash.service`), since this script
#   regenerates the base unit file on every run.
#
# Safety note: all executable logic lives inside main(), which is invoked
# only on the final line of this file. A POSIX shell must parse a function
# body in full — matching every brace — before it can run any of it, so if
# this file is truncated or only partially downloaded (e.g. a `curl | sh`
# that gets cut off), the shell either hits a parse error and exits before
# doing anything, or never reaches the trailing `main "$@"` call at all.
# Nothing above this point (the function definitions) mutates the system by
# itself. Do not add top-level statements outside function bodies below
# this note, and do not put anything after the final `main "$@"` call.

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
        # Resolve the tag to an immutable commit SHA. Tags can be moved by
        # a repo owner after the fact; a commit SHA cannot. We fetch the
        # tag ref, then dereference annotated tags to their target commit.
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
        # Prefer the published release asset (kavkash-<tag>.tar.gz) — it can
        # be verified against the SHA256SUMS published alongside. Fall back
        # to GitHub's auto-generated archive when the release has no asset.
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
            # got a tag name but couldn't resolve a SHA for it — fall back to
            # the tag ref directly; less verifiable but still a named release
            url="https://github.com/$KAVKASH_REPO/archive/refs/tags/$tag.tar.gz"
            resolved_sha="(unresolved — GitHub API did not return a commit SHA for this tag)"
            warn "could not resolve tag '$tag' to a commit SHA; installing by tag name only"
            say "kavkash: fetching release '$tag'"
        fi
    else
        # no stable release resolvable at all — fall back to branch HEAD
        url="https://github.com/$KAVKASH_REPO/archive/refs/heads/$KAVKASH_BRANCH.tar.gz"
        tag="(none — no stable release found)"
        resolved_sha="(unresolved — installed from moving branch HEAD, not a pinned commit)"
        warn "no stable release found for $KAVKASH_REPO; falling back to branch" \
            "'$KAVKASH_BRANCH'. This is a moving target — re-running this" \
            "installer later may install different code even with an" \
            "unchanged install.sh."
        say "kavkash: fetching branch '$KAVKASH_BRANCH'"
    fi

    # Best-effort: look for a published checksum asset on the release (GitHub
    # doesn't generate these itself; they exist only if upstream publishes one).
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

    for f in includes.sh hook.sh server.sh processor.sh import.sh functions.bash functions.fish functions.zsh; do
        install -m 755 "$src/$f" "$KAV_DATA_HOME/$f"
    done

    [ -f "$src/LICENSE" ] && install -m 644 "$src/LICENSE" "$KAV_DATA_HOME/LICENSE"
    [ -f "$src/README.md" ] && install -m 644 "$src/README.md" "$KAV_DATA_HOME/README.md"
    [ -f "$src/VERSION" ] && install -m 644 "$src/VERSION" "$KAV_DATA_HOME/VERSION"
}

# --- systemd --user integration --------------------------------------------

systemd_usable() {
    # True only if: systemd is PID 1 (or at least present as init), the
    # systemctl binary exists, AND a --user bus is actually reachable. All
    # three are required — having the binary installed doesn't mean a user
    # session/bus exists (common in minimal containers, chroots, WSL1, or
    # non-systemd distros that ship systemctl as a compat shim).
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
Restart=on-failure
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
    # Opt in via KAVKASH_IMPORT=1/0; otherwise prompt. Under curl|sh stdin
    # is the script pipe, not a terminal — read the answer from /dev/tty.
    # Import writes straight to the DB and needs no running daemon.
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
        "$KAV_DATA_HOME/import.sh" || warn "history import failed (see error above)"
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
    if [ "$verified" != "yes" ]; then
        say "              (checksum NOT verified against an upstream-published value —"
        say "               see INSTALLED_REVISION for the tarball_sha256 that was installed)"
    fi
    say ""
    say "next steps:"

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
    say "              (requires bash-preexec: https://github.com/rcaloras/bash-preexec)"
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
    say "       import now, or any time later:"
    say "       $KAV_DATA_HOME/import.sh   (idempotent — safe to re-run)"
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

    have curl || have wget || die "need curl or wget to download kavkash"
    have tar || die "need tar to unpack kavkash"

    resolve_source
    fetch_and_verify
    unpack
    install_files
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
