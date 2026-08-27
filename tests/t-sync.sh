#!/bin/sh
# t-sync.sh — the installed copy must match the repo. The suite tests
# the repo (KAVKASH_DIR); your shell sources the INSTALLED copy, so a
# stale install diverges silently while tests stay green (that is how
# the walk-mode metadata leak shipped). Skips when no installation
# exists (CI containers, fresh machines).
. "$(dirname "$0")/lib.sh"

install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"
if [ ! -f "$install_dir/functions.bash" ]; then
    echo "t-sync.sh: no installation at $install_dir — skipping (the suite tested the repo copy)"
    t_summary
    exit 0
fi

diverged=""
for f in includes.sh hook.sh server.sh processor.sh query.sh picker.sh \
    delete.sh import.sh backup.sh kavkash \
    functions.bash functions.zsh functions.fish \
    VERSION README.md LICENSE; do
    if ! cmp -s "$KAVKASH_DIR/$f" "$install_dir/$f"; then
        diverged="$diverged $f"
    fi
done

t_begin "installed copy matches the repo"
if [ -z "$diverged" ]; then
    t_ok
else
    t_fail "diverged:$diverged — re-sync them (the installer's files live under $install_dir)"
fi
t_summary
