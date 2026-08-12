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

# _hist_picker — the single fzf widget behind Ctrl+R and F6/F7/F8 (see
# functions.bash for the design rationale; fish mirrors it). Accept: Enter
# runs the picked command, Tab pastes it onto the line.
function _hist_picker
    set -l count $argv[1]
    set -l init_q $argv[2]
    set -l cwd $argv[3]
    set -l session $argv[4]
    set -l label all
    set -l prompt "search> "
    if test -n "$cwd"
        set label "dir $cwd"
        set prompt "dir> "
    else if test -n "$session"
        set label "session"
        set prompt "sess> "
    end
    set -l scope_file (mktemp)
    or return 0
    printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
    set -l picker $_HIST_PICKER
    # fzf stderr must stay on the terminal (2>/dev/null blanks the UI);
    # </dev/null keeps the tty out of its stdin — start:reload drives the
    # list. count=0 = ALL distinct commands, loaded once (no window, no
    # paging); fzf filters the search text in-memory; F6-F8 re-query the
    # scope server-side via picker.sh switch. read -z: NUL-delimited
    # capture (fish variables can't hold NUL, so no command substitution).
    # print()+accept NUL-frames "key\0<cmd>\0"; the awk turns that into
    # "key\n<cmd>".
    set -l picked
    fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt "$prompt" --query "$init_q" --read0 --print0 \
        --header "search · all · $label · F6 all F7 dir F8 sess · tab paste · enter run" \
        --bind "start:reload-sync:$picker load $count $scope_file" \
        --bind "f6:transform:$picker switch $scope_file '' '' all $count" \
        --bind "f7:transform:$picker switch $scope_file '$PWD' '' dir $count" \
        --bind "f8:transform:$picker switch $scope_file '' '$_hist_sess' sess $count" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' \
        < /dev/null \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 { printf "%s\n%s", key, $0 }' | read -z picked
    rm -f "$scope_file"

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

# Up/Down: walk ALL history one command per press — Up steps back one (no
# cap — the server's OFFSET on the rowid index makes deep steps cheap),
# Down steps forward and blanks the line at the bottom. The index resets
# after every executed command (_hist_postexec) and on Ctrl+C, so a fresh
# Up always starts at the newest command.
function _hist_step_up
    set -q _kav_step_idx; or set -g _kav_step_idx 0
    set -g _kav_step_idx (math $_kav_step_idx + 1)
    set -l cmd ""
    "$_HIST_SCRIPT_DIR/query.sh" 1 "" "" "" (math $_kav_step_idx - 1) | read -z cmd
    if test -n "$cmd"
        commandline -r "$cmd"
        commandline -f repaint
    else
        set -g _kav_step_idx (math $_kav_step_idx - 1)   # history exhausted — stay put
    end
end

function _hist_step_down
    set -q _kav_step_idx; or set -g _kav_step_idx 0
    if test $_kav_step_idx -le 1
        set -g _kav_step_idx 0
        commandline -r ""
        commandline -f repaint
        return
    end
    set -g _kav_step_idx (math $_kav_step_idx - 1)
    set -l cmd ""
    "$_HIST_SCRIPT_DIR/query.sh" 1 "" "" "" (math $_kav_step_idx - 1) | read -z cmd
    if test -n "$cmd"
        commandline -r "$cmd"
        commandline -f repaint
    else
        set -g _kav_step_idx 0   # defensive: the fetch came up empty
        commandline -r ""
        commandline -f repaint
    end
end

# Ctrl+R: search picker seeded with the current line (all distinct commands).
function _hist_search
    _hist_picker 0 (commandline -b)
end

# Scope variants: F6 all, F7 current dir (+subtree), F8 this shell session.
function _hist_scope_all
    _hist_picker 0 (commandline -b) "" ""
end
function _hist_scope_dir
    _hist_picker 0 (commandline -b) "$PWD" ""
end
function _hist_scope_sess
    _hist_picker 0 (commandline -b) "" "$_hist_sess"
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
    set -e _kav_step_idx   # Up/Down stepper starts fresh after every command
    if test -n "$__hist_corr"
        set -l now (date +%s%3N 2>/dev/null)
        [ -n "$now" ]; or set now (date +%s)000
        "$_HIST_HOOK" U "$__hist_corr" "$s" (math "$now - $__hist_t0") &
        set -g __hist_corr ""
    end
end

# fish_user_key_bindings — register all key bindings.
# Enter is NOT bound — fish's own Enter executes (the stepper resets on
# postexec). Ctrl+C IS bound: it cancels AND resets the stepper index.
#
# fzf >= 0.54 required — older versions can't render the raw multi-line
# rows the server sends; the bindings are skipped, not degraded.
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
        bind --user up _hist_step_up
        bind --user -M insert up _hist_step_up
        bind --user \e\[A _hist_step_up
        bind --user -M insert \e\[A _hist_step_up
        bind --user \eOA _hist_step_up
        bind --user -M insert \eOA _hist_step_up
        bind --user down _hist_step_down
        bind --user -M insert down _hist_step_down
        bind --user \e\[B _hist_step_down
        bind --user -M insert \e\[B _hist_step_down
        bind --user \eOB _hist_step_down
        bind --user -M insert \eOB _hist_step_down
        bind --user \cr _hist_search
        bind --user -M insert \cr _hist_search
        bind --user \e\[17~ _hist_scope_all
        bind --user -M insert \e\[17~ _hist_scope_all
        bind --user \e\[18~ _hist_scope_dir
        bind --user -M insert \e\[18~ _hist_scope_dir
        bind --user \e\[19~ _hist_scope_sess
        bind --user -M insert \e\[19~ _hist_scope_sess
        # Ctrl+C: cancel AND reset the stepper index (postexec doesn't fire
        # for a cancelled line); bound in both default and insert modes.
        bind --user \cc "set -e _kav_step_idx; commandline -f cancel-commandline"
        bind --user -M insert \cc "set -e _kav_step_idx; commandline -f cancel-commandline"
    end

    # Apply bindings now: fish only auto-calls fish_user_key_bindings at
    # startup, so a mid-session `source functions.fish` would otherwise
    # never bind.
    fish_user_key_bindings
else
    echo 'kavkash: fzf >= 0.54 required (found '"$_kav_fzf_ver"') — picker disabled; Up/Ctrl-R keep fish defaults' >&2
end
