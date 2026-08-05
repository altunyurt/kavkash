# kavkash fish integration — source from config.fish.
# Socket path must match includes.sh: ${XDG_RUNTIME_DIR}/kavkash/history.sock.
# fish cannot source includes.sh (POSIX sh syntax), so these stay duplicated
# — keep in sync.
if set -q XDG_RUNTIME_DIR
    set -g _HIST_SOCK "$XDG_RUNTIME_DIR/kavkash/history.sock"
else
    set -g _HIST_SOCK "/tmp/kavkash/history.sock"
end
# Directory containing this file (project root); hook.sh/query.sh/picker.sh
# live here. Resolved to a REAL path: fish refuses to exec command paths
# containing "..".
set -g _HIST_SCRIPT_DIR (dirname (status filename))
set -g _HIST_HOOK (realpath "$_HIST_SCRIPT_DIR/hook.sh")
set -g _HIST_PICKER (realpath "$_HIST_SCRIPT_DIR/picker.sh")

# _hist_picker — the single fzf widget behind both Up and Ctrl+R (see
# functions.bash for the design rationale; fish mirrors it). Accept: Enter
# runs the picked command, Tab pastes it onto the line.
function _hist_picker
    set -l count $argv[1]
    set -l init_q $argv[2]
    set -l win $count
    if test $win -gt 1000
        set win 1000
    end
    set -l win_file (mktemp)
    or return 0
    printf '%s\n' "$win" > "$win_file"
    # NOTE: fzf's stderr must stay on the terminal (a 2>/dev/null here
    # renders a blank UI); </dev/null keeps the tty out of its stdin —
    # start:reload drives the list. read -z: NUL-delimited capture — fish
    # variables can't hold NUL, so no command substitution. print()+accept
    # NUL-frames "key\0<cmd>\0"; the awk turns that into "key\n<cmd>".
    set -l picked
    fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt 'history> ' --query "$init_q" --read0 --print0 \
        --header 'f5: older · tab: paste · enter: run' \
        --bind "start:reload-sync:$_HIST_PICKER $win_file $count load" \
        --bind "result:transform:$_HIST_PICKER $win_file $count" \
        --bind "f5:transform:$_HIST_PICKER $win_file $count force" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' \
        < /dev/null \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 { printf "%s\n%s", key, $0 }' | read -z picked
    rm -f "$win_file"

    # fzf ran as a full-screen app inside this binding; fish's deferred
    # redraw won't repaint the prompt it clobbered. Force a repaint.
    commandline -f repaint

    test -n "$picked"; or return 0
    set -l key (printf '%s' "$picked" | head -n1)
    set -l cmd
    printf '%s' "$picked" | sed '1d' | read -z cmd
    test -n "$cmd"; or return 0
    # read -z keeps trailing newlines — awk above omits the final one, or
    # the buffer would end with a blank, prompt-less line.
    commandline -r "$cmd"
    if test "$key" = "tab"
        # Tab: paste only, edit, then Enter runs it.
    else
        # Enter: paste and run.
        commandline -f execute
    end
end

# Up: picker over the 500 newest commands. Down is deliberately unbound.
function _hist_up
    _hist_picker 500 ""
end

# Ctrl+R: picker seeded with the current line, 10k cap.
function _hist_search
    _hist_picker 10000 (commandline -b)
end

# preexec mints the correlation id + start time; postexec reports exit +
# duration for that id (see processor.sh U). Skip command-substitution
# spawns (e.g. fzf inside _hist_picker) so only typed commands are stored.
set -g __hist_corr ""
set -g __hist_t0 0

function _hist_preexec --on-event fish_preexec
    status is-command-substitution; and return 0
    [ -n "$argv[1]" ]; or return 0

    set -l t0 (date +%s%3N 2>/dev/null)
    [ -n "$t0" ]; or set t0 (date +%s)000
    set -g __hist_t0 $t0
    set -g __hist_corr ("$_HIST_HOOK" W "$argv[1]" "$PWD")
end

# fish_postexec fires after a command line finishes; $status is the line's
# exit code — captured FIRST before anything else runs.
function _hist_postexec --on-event fish_postexec
    set -l s $status
    if test -n "$__hist_corr"
        set -l now (date +%s%3N 2>/dev/null)
        [ -n "$now" ]; or set now (date +%s)000
        "$_HIST_HOOK" U "$__hist_corr" "$s" (math "$now - $__hist_t0") &
        set -g __hist_corr ""
    end
end

# fish_user_key_bindings — register all key bindings.
# Enter and Ctrl+C are NOT bound — fish's own Enter executes and Ctrl+C
# cancels.
#
# fzf >= 0.54 required: multi-line display (0.53), print() (0.53), transform +
# FZF_* env + result event (0.45/0.46), start:reload without an initial reader
# and the --sync render guarantee (0.54). Older fzf can't render the raw
# multi-line rows the server now sends, so the bindings are skipped, not
# degraded.
set -l _kav_fzf_ver (fzf --version 2>/dev/null | awk 'NR == 1 { print $1 }')
if test -n "$_kav_fzf_ver"; and printf '%s\n' "$_kav_fzf_ver" | awk -F. 'NR == 1 { exit ($1 > 0 || $2 >= 54) ? 0 : 1 }'
    function fish_user_key_bindings
        # erase any user bindings for these keys so re-sourcing this file never
        # leaves stale handlers bound
        bind --user --erase up 2>/dev/null
        bind --user --erase down 2>/dev/null
        bind --user --erase \cr 2>/dev/null

        # Bind by keyname AND by raw escape sequence: fish resolves incoming
        # bytes against raw-sequence bindings first, so a keyname-only binding
        # can lose to the preset up-line (fish's own history).
        bind --user up _hist_up
        bind --user -M insert up _hist_up
        bind --user \e\[A _hist_up
        bind --user -M insert \e\[A _hist_up
        bind --user \eOA _hist_up
        bind --user -M insert \eOA _hist_up
        bind --user \cr _hist_search
        bind --user -M insert \cr _hist_search
    end

    # Apply bindings now: fish only auto-calls fish_user_key_bindings at
    # startup, so a mid-session `source functions.fish` would otherwise
    # never bind.
    fish_user_key_bindings
else
    echo 'kavkash: fzf >= 0.54 required (found '"$_kav_fzf_ver"') — picker disabled; Up/Ctrl-R keep fish defaults' >&2
end
