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
# runs the picked command, Tab pastes it onto the line. mode: "walk" (Up)
# or "search" (Ctrl+R) — shown in the fzf prompt/header.
function _hist_picker
    set -l count $argv[1]
    set -l init_q $argv[2]
    set -l mode walk
    test -n "$argv[3]"; and set mode $argv[3]
    set -l cwd $argv[4]
    set -l session $argv[5]
    set -l label all
    set -l prompt "$mode> "
    if test -n "$cwd"
        set label "dir $cwd"
        set prompt "dir> "
    else if test -n "$session"
        set label "session"
        set prompt "sess> "
    end
    set -l win $count
    if test $win -gt 1000
        set win 1000
    end
    set -l win_file (mktemp)
    or return 0
    set -l scope_file (mktemp)
    or begin
        rm -f "$win_file"
        return 0
    end
    printf '%s\n' "$win" > "$win_file"
    printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
    set -l picker $_HIST_PICKER
    # fzf stderr must stay on the terminal (2>/dev/null blanks the UI);
    # </dev/null keeps the tty out of its stdin — start:reload drives the
    # list. read -z: NUL-delimited capture (fish variables can't hold NUL,
    # so no command substitution). print()+accept NUL-frames
    # "key\0<cmd>\0"; the awk turns that into "key\n<cmd>". Scope lives in
    # SCOPE_FILE; every reload goes through picker.sh load (start, growth,
    # F5, F6-F8) so win and scope never diverge.
    set -l picked
    fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt "$prompt" --query "$init_q" --read0 --print0 \
        --header "$mode · $count newest · $label · F6 all F7 dir F8 sess · f5 older · tab paste · enter run" \
        --bind "start:reload-sync:$picker load $win_file $count $scope_file" \
        --bind "result:transform:$picker decide $win_file $count $scope_file" \
        --bind "f5:transform:$picker decide $win_file $count $scope_file force" \
        --bind "f6:transform:$picker switch $scope_file '' '' all $win_file $count" \
        --bind "f7:transform:$picker switch $scope_file '$PWD' '' dir $win_file $count" \
        --bind "f8:transform:$picker switch $scope_file '' '$_hist_sess' sess $win_file $count" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' \
        < /dev/null \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 { printf "%s\n%s", key, $0 }' | read -z picked
    rm -f "$win_file" "$scope_file"

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

# Up: picker over the 500 newest commands (walk mode). Down is deliberately unbound.
function _hist_up
    _hist_picker 500 "" walk
end

# Ctrl+R: picker seeded with the current line (search mode), 10k cap.
function _hist_search
    _hist_picker 10000 (commandline -b) search
end

# Scope variants: F6 all, F7 current dir (+subtree), F8 this shell session.
function _hist_scope_all
    _hist_picker 10000 (commandline -b) search "" ""
end
function _hist_scope_dir
    _hist_picker 10000 (commandline -b) search "$PWD" ""
end
function _hist_scope_sess
    _hist_picker 10000 (commandline -b) search "" "$_hist_sess"
end

# preexec mints the correlation id + start time; postexec reports exit +
# duration for that id (see processor.sh U). Skip command-substitution
# spawns (e.g. fzf inside _hist_picker) so only typed commands are stored.
set -g __hist_corr ""
set -g __hist_t0 0

# Session token: one per interactive shell, minted at source time (rc files
# re-run on `exec`, so the new shell gets a fresh token — never inherit).
# Carried on every W; session scope in the picker matches on it.
if test -r /proc/sys/kernel/random/uuid
    set -g _hist_sess (cat /proc/sys/kernel/random/uuid)
else
    set -g _hist_sess (od -An -N16 -tx1 /dev/urandom 2>/dev/null | string replace -ra '[[:space:]]' '')
end

function _hist_preexec --on-event fish_preexec
    status is-command-substitution; and return 0
    [ -n "$argv[1]" ]; or return 0

    set -l t0 (date +%s%3N 2>/dev/null)
    [ -n "$t0" ]; or set t0 (date +%s)000
    set -g __hist_t0 $t0
    set -g __hist_corr ("$_HIST_HOOK" W "$argv[1]" "$PWD" "$_hist_sess")
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
        bind --user --erase \e\[17~ 2>/dev/null
        bind --user --erase \e\[18~ 2>/dev/null
        bind --user --erase \e\[19~ 2>/dev/null

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
        bind --user \e\[17~ _hist_scope_all
        bind --user -M insert \e\[17~ _hist_scope_all
        bind --user \e\[18~ _hist_scope_dir
        bind --user -M insert \e\[18~ _hist_scope_dir
        bind --user \e\[19~ _hist_scope_sess
        bind --user -M insert \e\[19~ _hist_scope_sess
    end

    # Apply bindings now: fish only auto-calls fish_user_key_bindings at
    # startup, so a mid-session `source functions.fish` would otherwise
    # never bind.
    fish_user_key_bindings
else
    echo 'kavkash: fzf >= 0.54 required (found '"$_kav_fzf_ver"') — picker disabled; Up/Ctrl-R keep fish defaults' >&2
end
