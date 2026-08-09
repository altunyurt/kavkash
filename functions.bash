# kavkash bash integration — source from .bashrc. Self-contained: no
# bash-preexec — recording is a DEBUG-trap preexec + PROMPT_COMMAND.

# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$_SCRIPT_DIR/includes.sh"

# Interactive tty settings at shell start (before readline engages). fzf
# leaves readline's raw mode behind; an eval'd command that reads the tty
# needs echo/line editing/signals back — restore this before running it.
_hist_stty=$(stty -g 2> /dev/null || true)

# --- atuin-borrowed: readline macro-chain for native accept-line ---
# (atuin: crates/atuin/src/shell/atuin.bash, __atuin_bind_impl / __atuin_widget_run)
# bind -x widgets can't call accept-line, so atuin dispatches via a two-step
# macro chain: the user key is a string macro queuing a sentinel chain
# (\C-r -> "\C-x\C-_A1\a\C-x\C-_A0\a"); the head is bind -x'd to the widget,
# and on Enter the widget swaps the tail between its default no-op "" and
# accept-line. Readline then accepts the line natively — history, prompt,
# $?, the DEBUG-trap preexec and PROMPT_COMMAND precmd all fire exactly as
# for a typed command (real exit code + duration). Tab/cancel leave the tail
# "" and the line on the buffer.
# Deviation: atuin re-binds only the triggering keymap; we rebind all three
# standard keymaps — the sentinel chain is never typed by humans, so a stale
# accept-line binding is unreachable. bash >= 4.3 (multi-byte bind -x
# keyseqs) and non-ble.sh required; both fall back to atuin's
# __atuin_accept_line print+eval in _hist_picker.
_hist_macro_bash=0
if (( BASH_VERSINFO[0] >= 5 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3 )) \
        && [[ -z ${BLE_ATTACHED-} ]]; then
    _hist_macro_bash=1
    _hist_macro_sentinel='\C-x\C-_A0\a'   # tail: no-op "", or accept-line on Enter
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

# _hist_picker — the fzf widget behind Up, Ctrl+R and F6/F7/F8.
#   count:     DB cap (Up=500, Ctrl+R=10000)
#   init_q:    search seed — Ctrl+R uses the current line, Up empty
#   mode:      "walk" (Up) or "search" (Ctrl+R), shown in the fzf header
#   cwd/session: scope (empty = global); filtered server-side BEFORE the
#               LIMIT, so a scoped command from long ago survives the
#               window cut; fzf filters keywords in-memory.
# Design: loads a *window* of newest commands via start:reload-sync, fzf
# filters in-memory (no per-keystroke DB trips, full fzf syntax). picker.sh
# grows the window from fzf events: a result-transform doubles it when
# exhausted (0 matches, or all match); f5 forces the next page. --sync
# resolves the cascade before first paint; --track keeps the cursor across
# reloads. Commands go over the wire raw — multi-line rows display natively
# (fzf >= 0.53).
_hist_picker() {
    local count="$1" init_q="${2:-}" mode="${3:-walk}" cwd="${4:-}" session="${5:-}"
    local picked key cmd win win_file scope_file label prompt picker
    _hist_armed=0   # disarm during the widget: the trap must not record the
                    # widget's own commands (incl. the fallback's eval'd
                    # command); the native-accept path re-arms at the end so
                    # the accepted line records normally
    if (( _hist_macro_bash )); then
        # reset the sentinel tail to no-op for this run — a previous Enter
        # run left it bound to accept-line, and the queued sentinel after
        # this widget would otherwise execute instead of paste
        for _hist_km in emacs vi-insert vi-command; do
            bind -m "$_hist_km" "\"$_hist_macro_sentinel\": \"\""
        done
        unset _hist_km
    fi
    if [[ -n "$cwd" ]]; then
        label="dir $cwd"; prompt="dir> "
    elif [[ -n "$session" ]]; then
        label="session"; prompt="sess> "
    else
        label="all"; prompt="$mode> "
    fi
    win=$count
    (( win > 1000 )) && win=1000
    win_file=$(mktemp) || {
        _hist_armed=1
        return 0
    }
    scope_file=$(mktemp) || {
        rm -f "$win_file"
        _hist_armed=1
        return 0
    }
    printf '%s\n' "$win" > "$win_file"
    printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
    picker="$_SCRIPT_DIR/picker.sh"
    # fzf stderr must stay on the terminal (2>/dev/null blanks the UI);
    # </dev/null keeps the tty out of its stdin — start:reload drives the
    # list. print()+accept NUL-frames "key\0<cmd>\0"; awk turns that into
    # "key\n<cmd>". Scope lives in SCOPE_FILE; every reload (start, growth,
    # F5, F6-F8) goes through picker.sh load, so win and scope never diverge.
    # F6/F7/F8 switch scope inside the picker via picker.sh switch, which
    # rewrites the scope file and prints the reload action for transform.
    picked=$(fzf --height 15 --no-sort --track --sync --highlight-line \
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
            NR == 2 { printf "%s\n%s\n", key, $0 }')
    rm -f "$win_file" "$scope_file"

    if [[ -n "$picked" ]]; then
        key="${picked%%$'\n'*}"
        cmd="${picked#*$'\n'}"
        if [[ -n "$cmd" ]]; then
            if [[ -z "$key" ]]; then
                if (( _hist_macro_bash )); then
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
                    prompt_repr=${prompt_repr//[$'\001\002']}
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
                        "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0
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
    _hist_armed=1   # re-arm on every exit path: the next typed line records again
}

# Up: picker over the 500 newest commands (walk mode). Down is deliberately unbound.
_hist_up() { _hist_picker 500 "" walk; }

# Ctrl+R: picker seeded with the current line (search mode), 10k cap.
_hist_search() { _hist_picker 10000 "$READLINE_LINE" search; }

# Scope variants: F6 all, F7 current dir (+subtree), F8 this shell session.
_hist_scope_all() { _hist_picker 10000 "$READLINE_LINE" search "" ""; }
_hist_scope_dir() { _hist_picker 10000 "$READLINE_LINE" search "$PWD" ""; }
_hist_scope_sess() { _hist_picker 10000 "$READLINE_LINE" search "" "$_hist_sess"; }

# --- capture: preexec (DEBUG trap) + precmd (PROMPT_COMMAND) ---
#
# bash has no preexec event, so kavkash synthesizes one with a DEBUG trap
# (the same trick bash-preexec uses). Empirically, in interactive bash:
#   - the trap fires before EVERY simple command, but NOT recursively (no
#     re-entry inside the trap body) and NOT in subshells
#   - it fires once per simple command of a line (`a && b` twice) and for
#     commands in PROMPT_COMMAND — filtered by the history-index check
#   - it fires for bind -x widget invocations (e.g. the picker) — filtered
#     the same way, since history doesn't grow
#   - it does NOT fire for function definitions — but the PROMPT_COMMAND
#     fire at the next prompt sees the history growth and records the line
#     then (real exit code, prompt-sized duration); the precmd fallback
#     below is only the safety net
#   - leading-space commands never reach history (HISTCONTROL=ignorespace)
#     and BASH_COMMAND only holds the current simple command, so they can't
#     be captured with the full line — documented limitation
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

_kav_hist_idx() {
    HISTTIMEFORMAT='' builtin history 1 | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

kav_preexec_record() {
    (( _hist_armed )) || return 0
    local line idx cmd
    line=$(HISTTIMEFORMAT='' builtin history 1)
    idx=$(_kav_hist_idx)
    [[ "$idx" =~ ^[0-9]+$ ]] || return 0
    (( idx > _hist_last_idx )) || return 0   # bind -x widget / prompt noise
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
}

kav_precmd_record() {
    local _hist_exit=$?    # capture FIRST — anything else clobbers it
    if [[ -n "$_hist_corr" ]]; then
        local _now=$(date +%s%3N 2> /dev/null || date +%s)
        "$_SCRIPT_DIR/hook.sh" U "$_hist_corr" "$_hist_exit" "$((_now - _hist_t0))"
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
    if (( _hist_initialized )); then
        cmd="${line#*[[:digit:]][* ] }"
        if [[ "$idx" =~ ^[0-9]+$ && $idx -gt _hist_last_idx && -n "$cmd" ]]; then
            _hist_last_idx=$idx
            local id
            id=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess")
            [[ -n "$id" ]] && "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0
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
# fzf >= 0.54 required: multi-line display (0.53), print() (0.53), transform +
# FZF_* env + result event (0.45/0.46), start:reload without an initial reader
# and the --sync render guarantee (0.54). Older fzf can't render the raw
# multi-line rows the server sends, so the picker is disabled, not degraded.
_kav_fzf_ver=$(fzf --version 2>/dev/null | awk 'NR == 1 { print $1 }')
if [ -n "$_kav_fzf_ver" ] && printf '%s\n' "$_kav_fzf_ver" | \
        awk -F. 'NR == 1 { exit ($1 > 0 || $2 >= 54) ? 0 : 1 }'; then
    if (( _hist_macro_bash )); then
        # Macro-chain dispatch (atuin-borrowed, machinery above): the key
        # queues the sentinel chain; on Enter the widget swaps the tail to
        # accept-line and the command runs natively.
        _hist_bind_widget '\C-r' _hist_search
        _hist_bind_widget '\e[A' _hist_up
        _hist_bind_widget '\e[17~' _hist_scope_all   # F6
        _hist_bind_widget '\e[18~' _hist_scope_dir   # F7
        _hist_bind_widget '\e[19~' _hist_scope_sess  # F8
    else
        # bash < 4.3 or ble.sh: direct bind -x + the print+eval Enter
        # fallback in _hist_picker (atuin's __atuin_accept_line).
        bind -x '"\C-r": _hist_search'
        bind -x '"\e[A": _hist_up'
        bind -x '"\e[17~": _hist_scope_all'   # F6
        bind -x '"\e[18~": _hist_scope_dir'   # F7
        bind -x '"\e[19~": _hist_scope_sess'  # F8
    fi
else
    printf 'kavkash: fzf >= 0.54 required (found %s) — picker disabled; Up/Ctrl-R keep shell defaults\n' \
        "${_kav_fzf_ver:-not installed}" >&2
fi
unset _kav_fzf_ver
