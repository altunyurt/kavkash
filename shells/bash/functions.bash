# Configuration: socket path and batch size for history navigation
_HIST_SOCK="${XDG_RUNTIME_DIR:-/tmp}/history.sock"
_HIST_BATCH=100

# _write_ns - encode a string as a netstring: "length:payload,"
# Uses a subshell to get byte count via wc -c (avoids bash-specific ${#var} for binary safety)
_write_ns() {
    printf '%s' "$1" | {
        len=$(LC_ALL=C wc -c | tr -d ' ')
        printf '%s:%s,' "$len" "$1"
    }
}

# _read_ns - decode a stream of netstrings into one field per line
# awk handles the parsing (see processor.sh for detailed comments)
_read_ns() {
    LC_ALL=C awk '
    BEGIN { RS = "\0" }
    {
        data = $0; pos = 1; len = length(data)
        while (pos <= len) {
            colon = index(substr(data, pos), ":")
            if (colon == 0) break
            colon += pos - 1
            lenstr = substr(data, pos, colon - pos)
            if (lenstr !~ /^(0|[1-9][0-9]*)$/) break
            n = lenstr + 0
            value = substr(data, colon + 1, n)
            if (length(value) != n) break
            term = colon + 1 + n
            if (substr(data, term, 1) != ",") break
            print value
            pos = term + 1
        }
    }'
}

# _hist_query - send a query to the server and return raw response
# Usage: _hist_query action [arg] [count]
# Protocol: "Q,action,arg[,count]" as concatenated netstrings
# Falls back from socat to nc if socat is unavailable
_hist_query() {
    local mode="$1"
    local arg="${2:-}"
    local count="${3:-}"

    local ns_action=$(_write_ns "$mode")
    local ns_arg=$(_write_ns "$arg")
    local payload="1:Q,${ns_action}${ns_arg}"

    if [[ -n "$count" ]]; then
        local ns_count=$(_write_ns "$count")
        payload="${payload}${ns_count}"
    fi

    if command -v socat >/dev/null 2>&1; then
        printf '%s' "$payload" | socat - UNIX-CONNECT:"$_HIST_SOCK" 2>/dev/null
    elif command -v nc >/dev/null 2>&1; then
        printf '%s' "$payload" | nc -U "$_HIST_SOCK" 2>/dev/null
    fi
}

# _hist_fetch - fetch a batch of commands and APPEND to __hist_resultset
# Args: offset count
# Appends (not replaces) so navigation through previously fetched items works
# when more history needs to be loaded from further back
_hist_fetch() {
    local offset="$1"
    local count="$2"
    local result
    result=$(_hist_query "up" "$offset" "$count")
    if [[ -n "$result" ]]; then
        # Append each line to the resultset
        while IFS= read -r line; do
            __hist_resultset+=("$line")
        done <<< "$result"
    fi
}

# _hist_search - Ctrl+R: open fzf with all commands for fuzzy search
# Queries server for all commands (capped at 10k), pipes through fzf,
# replaces the current line with the selected command
_hist_search() {
    local selected
    selected=$(_hist_query "search" "" | fzf --height 15 --no-sort --query "$READLINE_LINE")

    if [[ -n "$selected" ]]; then
        READLINE_LINE="$selected"
        READLINE_POINT=${#READLINE_LINE}
    fi
}

# _hist_stepper - handle Up/Down arrow history navigation
# State (all global, prefixed with __ to avoid clashes):
#   __hist_resultset[]  - array of commands, newest first (index 0 = most recent)
#   __hist_rsi          - current position in resultset (index to read next)
#   __hist_offset       - total items consumed from server (for next batch offset)
#
# Up:   if at end of resultset, fetch next batch (older commands).
#       Display resultset[__hist_rsi], advance both rsi and offset.
# Down: step back through resultset. If at start, clear line and reset.
_hist_stepper() {
    local direction="$1"

    # Initialize state on first invocation
    if [[ -z "${__hist_resultset+x}" ]]; then
        __hist_resultset=()
        __hist_rsi=0
        __hist_offset=0
    fi

    local rsi_len=${#__hist_resultset[@]}

    if [[ "$direction" == "up" ]]; then
        # Fetch more if we've consumed everything in the current batch
        if (( __hist_rsi >= rsi_len )); then
            local prev_len=$rsi_len
            _hist_fetch "$__hist_offset" "$_HIST_BATCH"
            rsi_len=${#__hist_resultset[@]}
            # If nothing new fetched, we've hit the end of history
            if (( rsi_len == prev_len )); then
                return
            fi
        fi
        READLINE_LINE="${__hist_resultset[$__hist_rsi]}"
        READLINE_POINT=${#READLINE_LINE}
        __hist_rsi=$(( __hist_rsi + 1 ))
        __hist_offset=$(( __hist_offset + 1 ))

    elif [[ "$direction" == "down" ]]; then
        if (( rsi_len > 0 && __hist_rsi > 0 )); then
            # Step back within the resultset
            __hist_rsi=$(( __hist_rsi - 1 ))
            __hist_offset=$(( __hist_offset - 1 ))
            READLINE_LINE="${__hist_resultset[$__hist_rsi]}"
            READLINE_POINT=${#READLINE_LINE}
        else
            # Past the start — clear line and reset state
            READLINE_LINE=""
            READLINE_POINT=0
            unset __hist_resultset __hist_rsi __hist_offset
        fi
    fi
}

# bind -x doesn't pass arguments directly, so wrap with direction argument
_hist_stepper_up() { _hist_stepper "up"; }
_hist_stepper_down() { _hist_stepper "down"; }

# _hist_reset - clear navigation state (called by preexec hook, NOT bound to Enter)
# Binding to Enter would intercept the normal command execution
_hist_reset() {
    unset __hist_resultset __hist_rsi __hist_offset
}

# _hist_cancel - Ctrl+C: clear state, cancel the current line
_hist_cancel() {
    unset __hist_resultset __hist_rsi __hist_offset
}

# _hist_bind_keys - register all key bindings
# bind -x runs the function directly (not just inserts text)
# \e[A = Up arrow, \e[B = Down arrow, \C-r = Ctrl+R, \C-c = Ctrl+C
# Enter is NOT bound — normal readline Enter executes the command.
# State is cleared by the DEBUG trap below before each command.
_hist_bind_keys() {
    bind -x '"\C-r": _hist_search'
    bind -x '"\e[A": _hist_stepper_up'
    bind -x '"\e[B": _hist_stepper_down'

    bind -x '"\C-c": _hist_cancel'
}

_hist_bind_keys

# Clear navigation state after each command completes
# PROMPT_COMMAND runs before displaying a new prompt (after a command finishes)
# DEBUG trap is NOT used — it fires too aggressively (before every simple command,
# including those inside bind -x functions like _hist_stepper).
__hist_old_prompt_cmd=${PROMPT_COMMAND:-}
PROMPT_COMMAND='_hist_reset 2>/dev/null; '"$__hist_old_prompt_cmd"
