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
# Version for the picker border label (read once per shell session).
set -g _hist_version (cat "$_HIST_SCRIPT_DIR/VERSION" 2>/dev/null)
if test -z "$_hist_version"
    set -g _hist_version '?'
end

# Daemon liveness: every client call guards on the socket first — a dead
# daemon must never die silently (recording stops, Up/Ctrl+R do nothing).
# Warn once per outage; the flag resets as soon as the daemon is reachable
# again, so a restart mid-session re-arms the warning.
function _kav_sock_up
    test -S $_HIST_SOCK; or return 1
    set -q _kav_daemon_warned; and set -e _kav_daemon_warned
    return 0
end
function _kav_warn_daemon
    set -q _kav_daemon_warned; and return 0
    set -g _kav_daemon_warned 1
    echo 'kavkash: daemon not running — history is not being saved. Start it with: systemctl --user start kavkash (or run '$_HIST_SCRIPT_DIR'/server.sh &)' >&2
end

# _hist_picker — the single fzf widget behind Ctrl+R and F6/F7/F8 (see
# functions.bash for the design rationale; fish mirrors it). Accept: Enter
# runs the picked command, Tab pastes it onto the line.
function _hist_picker
    set -l count $argv[1]
    set -l init_q $argv[2]
    set -l cwd $argv[3]
    set -l session $argv[4]
    _kav_sock_up; or begin
        _kav_warn_daemon
        return 0
    end
    set -l prompt "all> "
    if test -n "$cwd"
        set prompt "dir> "
    else if test -n "$session"
        set prompt "sess> "
    end
    set -l scope_file (mktemp)
    or return 0
    printf '%s\n%s\n' "$cwd" "$session" >"$scope_file"
    set -l picker $_HIST_PICKER
    set -l header "search · F6 all F7 dir F8 sess · shift-del delete · tab paste · enter run"
    # fzf stderr must stay on the terminal (2>/dev/null blanks the UI);
    # </dev/null keeps the tty out of its stdin — start:reload drives the
    # list; fzf filters the search text in-memory; F6-F8 re-query the
    # scope server-side via picker.sh switch. read -z: NUL-delimited
    # capture (fish variables can't hold NUL, so no command substitution).
    # print()+accept NUL-frames "key\0<cmd>\0"; the awk turns that into
    # "key\n<cmd>".
    set -l picked
    fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt "$prompt" --query "$init_q" --read0 --print0 \
        --delimiter "\x1f" --with-nth 1 --accept-nth 1 \
        --header "$header" \
        --border \
        --border-label "kavkash v$_hist_version" \
        --bind "start:reload-sync:$picker load $count $scope_file" \
        --bind "shift-delete:execute-silent($_HIST_SCRIPT_DIR/delete.sh {2})+reload-sync:$picker load $count $scope_file" \
        --bind "f6:transform:$picker switch $scope_file '' '' all $count" \
        --bind "f7:transform:$picker switch $scope_file '$PWD' '' dir $count" \
        --bind "f8:transform:$picker switch $scope_file '' '$_hist_sess' sess $count" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' </dev/null \
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
    printf '%s' "$picked" | sed 1d | read -z cmd
    test -n "$cmd"; or return 0
    # read -z keeps trailing newlines — awk above omits the final one, or
    # the buffer would end with a blank, prompt-less line.
    commandline -r "$cmd"
    if test "$key" = tab
        # Tab: paste only, edit, then Enter runs it.
    else
        # Enter: paste and run.
        commandline -f execute
    end
end

# Up/Down: walk all of history one distinct command per press — Up steps
# back, Down steps forward. A typed prefix narrows the walk: `git ` + Up
# cycles only `git …` commands; an empty line walks everything. The index
# resets after every executed command (_hist_postexec) and on Ctrl+C, so
# a fresh Up always starts at the newest command.
#
# Commands are prefetched into _kav_step_cache in batches of 50, so a
# press is a pure memory read with no daemon round trip; Down never
# queries at all. The walk is a stable snapshot — a command recorded
# mid-walk can't shift the OFFSET under the user's feet.
function _hist_step_up
    _kav_sock_up; or begin
        _kav_warn_daemon
        return 0
    end
    set -q _kav_step_idx; or set -g _kav_step_idx 0
    set -q _kav_step_cache; or set -g _kav_step_cache
    set -q _kav_step_eof; or set -g _kav_step_eof 0
    set -q _kav_step_prefix; or set -g _kav_step_prefix ""
    set -q _kav_step_orig; or set -g _kav_step_orig ""
    set -q _kav_step_last; or set -g _kav_step_last ""
    # An edited line starts a fresh search: when the buffer differs from
    # what the stepper last displayed, the previous walk is abandoned and
    # the line becomes the new prefix — clearing the line mid-walk thus
    # resets the offset. Untouched lines continue the same walk.
    set -l buf (commandline -b)[1]
    if test "$buf" != "$_kav_step_last"
        set -g _kav_step_prefix $buf
        set -g _kav_step_orig $buf
        set -g _kav_step_cache
        set -g _kav_step_eof 0
        set -g _kav_step_idx 0
    end
    # Refill when stepping past the cache (one daemon call per 50
    # presses). fish vars can't hold NUL, so the batch is staged through
    # a temp file and read back one record per `read -z`; awk strips the
    # \x1f<id> payload while the framing is still NUL-safe.
    if test $_kav_step_idx -ge (count $_kav_step_cache)
        test $_kav_step_eof -eq 1; and return 0
        set -l _kav_tmp (mktemp)
        "$_HIST_SCRIPT_DIR/query.sh" 50 "$_kav_step_prefix" "" "" $_kav_step_idx \
            | awk 'BEGIN { RS = ORS = "\0" } { sub(/\x1f[^\x1f]*$/, ""); print }' >$_kav_tmp
        set -l _kav_have (count $_kav_step_cache)
        while read -z _kav_item
            set -a _kav_step_cache $_kav_item
        end <$_kav_tmp
        rm -f $_kav_tmp
        if test (math (count $_kav_step_cache) - $_kav_have) -lt 50
            set -g _kav_step_eof 1
        end
        if test $_kav_step_idx -ge (count $_kav_step_cache)
            return 0 # history exhausted — stay put
        end
    end
    set -g _kav_step_idx (math $_kav_step_idx + 1)
    commandline -r $_kav_step_cache[$_kav_step_idx]
    set -g _kav_step_last $_kav_step_cache[$_kav_step_idx]
end

function _hist_step_down
    _kav_sock_up; or begin
        _kav_warn_daemon
        return 0
    end
    set -q _kav_step_idx; or set -g _kav_step_idx 0
    set -q _kav_step_orig; or set -g _kav_step_orig ""
    set -q _kav_step_last; or set -g _kav_step_last ""
    # An edited line abandons the walk: Down on a dirty line only resets
    # the offset (the user's text is kept; the next Up starts fresh).
    set -l buf (commandline -b)[1]
    if test "$buf" != "$_kav_step_last"
        set -g _kav_step_idx 0
        return 0
    end
    if test $_kav_step_idx -le 1
        # Bottom of the search: restore what the user typed (empty when
        # the walk had no prefix — today's behavior).
        set -g _kav_step_idx 0
        commandline -r $_kav_step_orig
        set -g _kav_step_last $_kav_step_orig
        return
    end
    set -g _kav_step_idx (math $_kav_step_idx - 1)
    # No query here: Down only re-treads ground Up already fetched.
    if set -q _kav_step_cache[$_kav_step_idx]
        commandline -r $_kav_step_cache[$_kav_step_idx]
        set -g _kav_step_last $_kav_step_cache[$_kav_step_idx]
    else
        set -g _kav_step_idx 0 # defensive: the cache was cleared mid-walk
        commandline -r $_kav_step_orig
        set -g _kav_step_last $_kav_step_orig
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

    _kav_sock_up; or begin
        _kav_warn_daemon
        return 0
    end

    set -l t0 (date +%s%3N 2>/dev/null)
    [ -n "$t0" ]; or set t0 (date +%s)000
    set -g __hist_t0 $t0
    set -g __hist_corr ("$_HIST_HOOK" W "$argv[1]" "$PWD" "$_hist_sess")
end

# fish_postexec fires after a command line finishes; $status is the line's
# exit code — captured FIRST before anything else runs.
function _hist_postexec --on-event fish_postexec
    set -l s $status
    set -e _kav_step_idx # Up/Down stepper starts fresh after every command
    set -e _kav_step_cache
    set -g _kav_step_eof 0
    set -e _kav_step_prefix _kav_step_orig _kav_step_last
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
        bind --user \cc "set -e _kav_step_idx _kav_step_cache _kav_step_prefix _kav_step_orig _kav_step_last; set -g _kav_step_eof 0; commandline -f cancel-commandline"
        bind --user -M insert \cc "set -e _kav_step_idx _kav_step_cache _kav_step_prefix _kav_step_orig _kav_step_last; set -g _kav_step_eof 0; commandline -f cancel-commandline"
    end

    # Apply bindings now: fish only auto-calls fish_user_key_bindings at
    # startup, so a mid-session `source functions.fish` would otherwise
    # never bind.
    fish_user_key_bindings
else
    echo 'kavkash: fzf >= 0.54 required (found '"$_kav_fzf_ver"') — picker disabled; Up/Ctrl-R keep fish defaults' >&2
end
