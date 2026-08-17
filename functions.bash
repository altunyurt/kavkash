# kavkash bash integration — source from .bashrc. Self-contained: no
# bash-preexec — recording is a DEBUG-trap preexec + PROMPT_COMMAND.

# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$_SCRIPT_DIR/includes.sh"

# Version for the picker border label (read once per shell session).
_hist_version=$(cat "$KAV_DATA_HOME/VERSION" 2> /dev/null || printf '?')

# Interactive tty settings at shell start (before readline engages). fzf
# leaves readline's raw mode behind; an eval'd command that reads the tty
# needs echo/line editing/signals back — restore this before running it.
_hist_stty=$(stty -g 2> /dev/null || true)

# Daemon liveness: every client call guards on the socket first — a dead
# daemon must never die silently (recording stops, Up/Ctrl+R do nothing).
# Warn once per outage; the flag resets as soon as the daemon is reachable
# again, so a restart mid-session re-arms the warning.
_hist_daemon_warned=0
_hist_sock_up() {
    if [[ -S "$KAV_SOCK_FILE" ]]; then
        _hist_daemon_warned=0
        return 0
    fi
    return 1
}
_hist_warn_daemon() { # record path (preexec) — plain message
    ((_hist_daemon_warned)) && return 0
    _hist_daemon_warned=1
    printf 'kavkash: daemon not running — history is not being saved. Start it with: systemctl --user start kavkash (or run %s/server.sh &)\n' "$_SCRIPT_DIR" >&2
}
_hist_warn_daemon_widget() {            # bind -x widgets — leading newline so
    ((_hist_daemon_warned)) && return 0 # readline's redraw can't eat it
    _hist_daemon_warned=1
    printf '\nkavkash: daemon not running — history is not being saved. Start it with: systemctl --user start kavkash (or run %s/server.sh &)\n' "$_SCRIPT_DIR" >&2
}

# --- atuin-borrowed: readline macro-chain for native accept-line ---
# bind -x widgets can't call accept-line, so the user key queues a
# two-step macro chain (\C-r -> "\C-x\C-_A1\a\C-x\C-_A0\a"): the head is
# bind -x'd to the widget, and on Enter the widget swaps the tail between
# its default no-op "" and accept-line. Readline then accepts the line
# natively — history, prompt, $?, the DEBUG-trap preexec and
# PROMPT_COMMAND precmd all fire exactly as for a typed command (real
# exit code + duration). Tab/cancel leave the tail "" and the line on the
# buffer. All three standard keymaps are rebound — the sentinel chain is
# never typed by humans, so a stale accept-line binding is unreachable.
# bash >= 4.3 (multi-byte bind -x keyseqs) and non-ble.sh required; both
# fall back to print+eval in _hist_picker.
_hist_macro_bash=0
if ((BASH_VERSINFO[0] >= 5 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3)) \
    && [[ -z ${BLE_ATTACHED-} ]]; then
    _hist_macro_bash=1
    _hist_macro_sentinel='\C-x\C-_A0\a' # tail: no-op "", or accept-line on Enter
    _hist_macro_n=0
    for _hist_km in emacs vi-insert vi-command; do
        bind -m "$_hist_km" "\"$_hist_macro_sentinel\": \"\""
    done
    unset _hist_km
fi

# Bind KEYSEQ to widget FN through the macro chain (only used when the macro
# path is active, above).
_hist_bind_widget() {
    local keyseq=$1 fn=$2
    _hist_macro_n=$((_hist_macro_n + 1))
    local chain="\\C-x\\C-_A${_hist_macro_n}\\a"
    for _hist_km in emacs vi-insert vi-command; do
        # the user key queues BOTH chains: the widget chain (head, bind -x)
        # and the sentinel (tail, swapped to accept-line on Enter)
        bind -m "$_hist_km" "\"$keyseq\": \"$chain$_hist_macro_sentinel\""
        bind -m "$_hist_km" -x "\"$chain\": $fn"
    done
    unset _hist_km
}

# _hist_picker — the fzf widget behind Ctrl+R and F6/F7/F8.
#   count:     0 = all distinct commands (server sends no LIMIT)
#   init_q:    search seed — the current line
#   cwd/session: scope (empty = global); applied server-side, so the
#               whole distinct set for the scope is loaded; fzf filters
#               the search text in-memory. The server deduplicates: one
#               row per distinct command, newest occurrence first (GROUP
#               BY command, MAX(id)).
# The full distinct set loads once via start:reload-sync and fzf filters
# in-memory (no per-keystroke DB trips, full fzf syntax). Scope switches
# (F6-F8) re-query server-side via picker.sh switch. Commands go over the
# wire raw — multi-line rows display natively.
_hist_picker() {
    local count="$1" init_q="${2:-}" cwd="${3:-}" session="${4:-}"
    local picked key cmd scope_file prompt picker header
    if ! _hist_sock_up; then
        _hist_warn_daemon_widget
        return 0
    fi
    _hist_armed=0 # disarm during the widget: the trap must not record the
    # widget's own commands (incl. the fallback's eval'd
    # command); the native-accept path re-arms at the end so
    # the accepted line records normally
    if ((_hist_macro_bash)); then
        # reset the sentinel tail to no-op for this run — a previous Enter
        # run left it bound to accept-line, and the queued sentinel after
        # this widget would otherwise execute instead of paste
        for _hist_km in emacs vi-insert vi-command; do
            bind -m "$_hist_km" "\"$_hist_macro_sentinel\": \"\""
        done
        unset _hist_km
    fi
    if [[ -n "$cwd" ]]; then
        prompt="dir> "
    elif [[ -n "$session" ]]; then
        prompt="sess> "
    else
        prompt="all> "
    fi
    scope_file=$(mktemp) || {
        _hist_armed=1
        return 0
    }
    printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
    picker="$_SCRIPT_DIR/picker.sh"
    header="search · F6 all F7 dir F8 sess · shift-del delete · tab paste · enter run"
    # fzf stderr must stay on the terminal (2>/dev/null blanks the UI);
    # </dev/null keeps the tty out of its stdin — start:reload drives the
    # list; fzf filters the search text in-memory. Scope lives in
    # SCOPE_FILE; F6/F7/F8 switch it via picker.sh switch, which rewrites
    # the file and prints change-prompt + reload-sync for transform.
    # print()+accept NUL-frames "key\0<cmd>\0"; awk turns that into
    # "key\n<cmd>".
    picked=$(fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt "$prompt" --query "$init_q" --read0 --print0 \
        --delimiter $'\x1f' --with-nth 1 --accept-nth 1 \
        --header "$header" \
        --border \
        --border-label "kavkash v$_hist_version" \
        --bind "start:reload-sync:$picker load $count $scope_file" \
        --bind "shift-delete:execute-silent($_SCRIPT_DIR/delete.sh {2})+reload-sync:$picker load $count $scope_file" \
        --bind "f6:transform:$picker switch $scope_file '' '' all $count" \
        --bind "f7:transform:$picker switch $scope_file '$PWD' '' dir $count" \
        --bind "f8:transform:$picker switch $scope_file '' '$_hist_sess' sess $count" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' \
        < /dev/null \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 { i = index($0, "\035"); if (i) $0 = substr($0, i + 1); printf "%s\n%s\n", key, $0 }')
    rm -f "$scope_file"

    if [[ -n "$picked" ]]; then
        key="${picked%%$'\n'*}"
        cmd="${picked#*$'\n'}"
        if [[ -n "$cmd" ]]; then
            if [[ -z "$key" ]]; then
                if ((_hist_macro_bash)); then
                    # Enter: native accept via the macro chain (machinery
                    # above) — set the buffer, swap the queued sentinel to
                    # accept-line. Readline accepts after this widget
                    # returns; the command displays as typed and preexec/
                    # precmd record it with the real exit code and duration.
                    # No eval, no stty juggling, no manual hook calls.
                    READLINE_LINE="$cmd"
                    READLINE_POINT=${#READLINE_LINE}
                    for _hist_km in emacs vi-insert vi-command; do
                        bind -m "$_hist_km" "\"$_hist_macro_sentinel\": accept-line"
                    done
                    unset _hist_km
                else
                    # Enter fallback (bash < 4.3 / ble.sh): atuin's
                    # __atuin_accept_line — print the prompt + command (as
                    # if typed), record it (history -s) and eval it. fzf
                    # left readline's raw mode behind, so restore the
                    # interactive stty around the eval. The DEBUG preexec is
                    # disarmed for this widget, so the eval'd command can't
                    # self-record; hook.sh does W here and U after with the
                    # real exit code.
                    local prompt_repr
                    if ((BASH_VERSINFO[0] > 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)); then
                        prompt_repr=${PS1@P}
                    else
                        prompt_repr='$ '
                    fi
                    # strip bash's \[ \] markers (/) from the prompt
                    prompt_repr=${prompt_repr//[$'\001\002']/}
                    printf '%s\n' "$prompt_repr$cmd"
                    history -s "$cmd"
                    READLINE_LINE=""
                    # don't leak the widget vars into a child bash
                    export -n READLINE_LINE READLINE_POINT 2> /dev/null || true
                    local stty_backup
                    stty_backup=$(stty -g 2> /dev/null || true)
                    if [[ -n "$_hist_stty" ]]; then
                        stty "$_hist_stty" 2> /dev/null
                    fi
                    local _hist_exit
                    eval "$cmd"
                    _hist_exit=$?
                    if [[ -n "$stty_backup" ]]; then
                        stty "$stty_backup" 2> /dev/null
                    fi
                    local id
                    id=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess")
                    if [[ -n "$id" ]]; then
                        "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0 "$cmd"
                    fi
                    # precmd won't run for this line (bind -x callbacks
                    # don't re-display the prompt), so sync the index
                    # baseline.
                    _hist_last_idx=$(_kav_hist_idx)
                fi
            else
                # Tab: paste onto the line; Enter will run it (and precmd
                # records).
                READLINE_LINE="$cmd"
                READLINE_POINT=${#READLINE_LINE}
            fi
        fi
    fi
    _hist_armed=1 # re-arm on every exit path: the next typed line records again
}

# Up/Down: walk all of history one distinct command per press — Up steps
# back, Down steps forward. A typed prefix narrows the walk: `git ` + Up
# cycles only `git …` commands; an empty line walks everything (today's
# behavior). The index resets on every new prompt (kav_precmd_record), so
# a fresh Up always starts at the newest command.
#
# Commands are prefetched into _hist_step_cache in batches of 50, so a
# press is a pure memory read with no daemon round trip; Down never
# queries at all. The cache resets with the index on every prompt, and
# the walk is a stable snapshot — a command recorded mid-walk can't
# shift the OFFSET under the user's feet.
_hist_step_idx=0
_hist_step_cache=()
_hist_step_eof=0
_hist_step_batch=50
_hist_step_prefix="" # search prefix; "" = walk all history
_hist_step_orig=""   # line as typed, restored at the bottom of the walk
_hist_step_last=""   # last line the stepper displayed (edit detection)
_hist_step_up() {
    local cmd
    if ! _hist_sock_up; then
        _hist_warn_daemon_widget
        return 0
    fi
    # An edited line starts a fresh search: when the buffer differs from
    # what the stepper last displayed, the previous walk is abandoned and
    # the line becomes the new prefix — clearing the line mid-walk thus
    # resets the offset. Untouched lines continue the same walk.
    if [[ "$READLINE_LINE" != "$_hist_step_last" ]]; then
        _hist_step_prefix=$READLINE_LINE
        _hist_step_orig=$READLINE_LINE
        _hist_step_cache=()
        _hist_step_eof=0
        _hist_step_idx=0
    fi
    # Refill when stepping past the cache (one daemon call per 50 presses).
    if ((_hist_step_eof == 0 && _hist_step_idx >= ${#_hist_step_cache[@]})); then
        local -a _hist_batch=()
        local _hist_item
        while IFS= read -r -d '' _hist_item; do
            _hist_item=${_hist_item%$'\x1f'*}   # drop the \x1f<id> payload
            _hist_item=${_hist_item#*$'\x1d'}   # drop the "dur ✓/✗ age" metadata prefix
            _hist_batch+=("$_hist_item")
        done < <("$_SCRIPT_DIR/query.sh" "$_hist_step_batch" "$_hist_step_prefix" "" "" "$_hist_step_idx")
        if ((${#_hist_batch[@]} == 0)); then
            _hist_step_eof=1
            return 0 # history exhausted — stay put
        fi
        ((${#_hist_batch[@]} < _hist_step_batch)) && _hist_step_eof=1
        _hist_step_cache+=("${_hist_batch[@]}")
    fi
    cmd=${_hist_step_cache[_hist_step_idx]}
    _hist_step_idx=$((_hist_step_idx + 1))
    READLINE_LINE="$cmd"
    READLINE_POINT=${#READLINE_LINE}
    _hist_step_last="$cmd"
}
_hist_step_down() {
    local cmd
    if ! _hist_sock_up; then
        _hist_warn_daemon_widget
        return 0
    fi
    # An edited line abandons the walk: Down on a dirty line only resets
    # the offset (the user's text is kept; the next Up starts fresh).
    if [[ "$READLINE_LINE" != "$_hist_step_last" ]]; then
        _hist_step_idx=0
        return 0
    fi
    if ((_hist_step_idx <= 1)); then
        # Bottom of the search: restore what the user typed (empty when
        # the walk had no prefix).
        _hist_step_idx=0
        READLINE_LINE="$_hist_step_orig"
        READLINE_POINT=${#READLINE_LINE}
        _hist_step_last="$_hist_step_orig"
        return
    fi
    _hist_step_idx=$((_hist_step_idx - 1))
    # No query here: Down only re-treads ground Up already fetched.
    cmd=${_hist_step_cache[_hist_step_idx - 1]}
    if [[ -n "$cmd" ]]; then
        READLINE_LINE="$cmd"
        READLINE_POINT=${#READLINE_LINE}
        _hist_step_last="$cmd"
    else
        _hist_step_idx=0 # defensive: the cache was cleared mid-walk
        READLINE_LINE="$_hist_step_orig"
        READLINE_POINT=${#READLINE_LINE}
        _hist_step_last="$_hist_step_orig"
    fi
}

# Ctrl+R: search picker seeded with the current line (all distinct commands).
_hist_search() { _hist_picker 0 "$READLINE_LINE"; }

# Scope variants: F6 all, F7 current dir (+subtree), F8 this shell session.
_hist_scope_all() { _hist_picker 0 "$READLINE_LINE" "" ""; }
_hist_scope_dir() { _hist_picker 0 "$READLINE_LINE" "$PWD" ""; }
_hist_scope_sess() { _hist_picker 0 "$READLINE_LINE" "" "$_hist_sess"; }

# --- capture: preexec (DEBUG trap) + precmd (PROMPT_COMMAND) ---
#
# bash has no preexec event, so kavkash synthesizes one with a DEBUG trap
# (the same trick bash-preexec uses). In interactive bash the trap fires
# before every simple command — but not recursively (no re-entry inside
# the trap body), not in subshells, and not for function definitions
# (the next prompt's history-growth check records those). Leading-space
# commands never reach history (HISTCONTROL=ignorespace) — and hook.sh
# skips them anyway, so they are never saved.
#
# Two guards:
#   _hist_armed — set ONLY at the end of PROMPT_COMMAND, so startup files
#                 (history not even loaded yet) and the first prompt can't
#                 fire; a real command consumes it. Widgets disarm it for
#                 their duration.
#   index check — a fire only records when history actually grew past the
#                 last recorded entry. That kills bind -x widgets,
#                 PROMPT_COMMAND's own commands, and blank Enters without
#                 needing to know which command is which.
_hist_armed=0
_hist_initialized=0
_hist_corr=""
_hist_t0=0
_hist_last_idx=0
_hist_last_cmd=""

_kav_hist_idx() {
    HISTTIMEFORMAT='' builtin history 1 | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

kav_preexec_record() {
    ((_hist_armed)) || return 0
    # Daemon down: warn (throttled) and stay armed — the next command after
    # a restart records normally instead of silently losing history.
    if ! _hist_sock_up; then
        _hist_warn_daemon
        return 0
    fi
    local line idx cmd
    line=$(HISTTIMEFORMAT='' builtin history 1)
    idx=$(_kav_hist_idx)
    [[ "$idx" =~ ^[0-9]+$ ]] || return 0
    ((idx > _hist_last_idx)) || return 0 # bind -x widget / prompt noise
    cmd="${line#*[[:digit:]][* ] }"
    [[ -n "$cmd" ]] || return 0
    _hist_last_idx=$idx
    _hist_armed=0
    if [[ "$cmd" == "exit" || "$cmd" == "logout" ]]; then
        # The shell exits before a backgrounded delivery could connect,
        # so the last command would be lost — send this one synchronously.
        "$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess" sync
        return 0
    fi
    _hist_t0=$(date +%s%3N 2> /dev/null || date +%s)
    _hist_corr=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess")
    _hist_last_cmd=$cmd
}

kav_precmd_record() {
    local _hist_exit=$? # capture FIRST — anything else clobbers it
    _hist_step_idx=0    # Up/Down stepper starts fresh at every prompt
    _hist_step_cache=()
    _hist_step_eof=0
    _hist_step_prefix=""
    _hist_step_orig=""
    _hist_step_last=""
    if [[ -n "$_hist_corr" ]]; then
        local _now=$(date +%s%3N 2> /dev/null || date +%s)
        "$_SCRIPT_DIR/hook.sh" U "$_hist_corr" "$_hist_exit" "$((_now - _hist_t0))" "$_hist_last_cmd"
        _hist_corr=""
    fi
    # Baseline the history index on the first prompt: history loads only
    # after the rc files, so pre-sourcing entries must not count as new.
    # After that, the prompt's own DEBUG fire already consumed any growth
    # (function definitions); this fallback records what slipped through,
    # exit code included, duration unknown (0).
    local line idx cmd
    line=$(HISTTIMEFORMAT='' builtin history 1)
    idx=$(_kav_hist_idx)
    if ((_hist_initialized)); then
        cmd="${line#*[[:digit:]][* ] }"
        if [[ "$idx" =~ ^[0-9]+$ && $idx -gt _hist_last_idx && -n "$cmd" ]]; then
            _hist_last_idx=$idx
            local id
            id=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess")
            [[ -n "$id" ]] && "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0 "$cmd"
        fi
    elif [[ "$idx" =~ ^[0-9]+$ ]]; then
        _hist_last_idx=$idx
        _hist_initialized=1
    fi
    _hist_armed=1
}

# Session token: one per interactive shell, minted at source time (rc files
# re-run on `exec`, so the new shell gets a fresh token — never inherited).
# Carried on every W; session scope in the picker matches on it.
_hist_sess=$(cat /proc/sys/kernel/random/uuid 2> /dev/null) || _hist_sess=$(od -An -N16 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')

# Run the recorder on every primary prompt via bash's PROMPT_COMMAND (array
# form in bash 5.1+, scalar before); kavkash's hook goes FIRST so $? is
# still the last command's exit status when it runs.
if [[ $(declare -p PROMPT_COMMAND 2> /dev/null) == declare\ -*a* ]]; then
    PROMPT_COMMAND=(kav_precmd_record "${PROMPT_COMMAND[@]}")
else
    PROMPT_COMMAND="kav_precmd_record${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

# Preempt any existing DEBUG trap (kavkash takes it over, like
# bash-preexec does); the guards above keep it inert outside commands.
trap kav_preexec_record DEBUG

# The widgets are bound below (readline can't call accept-line from a
# bind -x widget, so bash >= 4.3 routes them through atuin's macro chain,
# machinery above; older bash / ble.sh use plain bind -x and the print+eval
# Enter fallback). Enter and Ctrl+C are NOT bound — readline's defaults
# execute/cancel.
#
# fzf >= 0.54 required — older versions can't render the raw multi-line
# rows the server sends; the picker is disabled, not degraded.
_kav_fzf_ver=$(fzf --version 2> /dev/null | awk 'NR == 1 { print $1 }')
if [ -n "$_kav_fzf_ver" ] && printf '%s\n' "$_kav_fzf_ver" \
    | awk -F. 'NR == 1 { exit ($1 > 0 || $2 >= 54) ? 0 : 1 }'; then
    if ((_hist_macro_bash)); then
        # Macro-chain dispatch (atuin-borrowed, machinery above): the key
        # queues the sentinel chain; on Enter the widget swaps the tail to
        # accept-line and the command runs natively.
        _hist_bind_widget '\C-r' _hist_search
        _hist_bind_widget '\e[17~' _hist_scope_all  # F6
        _hist_bind_widget '\e[18~' _hist_scope_dir  # F7
        _hist_bind_widget '\e[19~' _hist_scope_sess # F8
    else
        # bash < 4.3 or ble.sh: direct bind -x + the print+eval Enter
        # fallback in _hist_picker (atuin's __atuin_accept_line).
        bind -x '"\C-r": _hist_search'
        bind -x '"\e[17~": _hist_scope_all'  # F6
        bind -x '"\e[18~": _hist_scope_dir'  # F7
        bind -x '"\e[19~": _hist_scope_sess' # F8
    fi
    # Up/Down need no macro chain: the stepper only sets the line, Enter is
    # readline's default accept (no eval, no hook calls).
    bind -x '"\e[A": _hist_step_up'
    bind -x '"\e[B": _hist_step_down'
else
    printf 'kavkash: fzf >= 0.54 required (found %s) — picker disabled; Up/Ctrl-R keep shell defaults\n' \
        "${_kav_fzf_ver:-not installed}" >&2
fi
unset _kav_fzf_ver
