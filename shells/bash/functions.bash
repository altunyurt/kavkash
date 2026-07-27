# Configuration
_HIST_SOCK="${XDG_RUNTIME_DIR:-/tmp}/history.sock"

# Netstring helpers
_write_ns() {
    printf '%s' "$1" | {
        len=$(LC_ALL=C wc -c | tr -d ' ')
        printf '%s:%s,' "$len" "$1"
    }
}

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

# Socket Communication Helper
_hist_query() {
    local mode="$1"
    local arg="$2"

    # Build netstring query: Q, action, arg
    local ns_action=$(_write_ns "$mode")
    local ns_arg=$(_write_ns "$arg")
    local payload="1:Q,${ns_action}${ns_arg}"

    printf '%s' "$payload" | socat - UNIX-CONNECT:"$_HIST_SOCK" 2>/dev/null
}

# fzf Search Trigger (Ctrl+R)
_hist_search() {
    local selected
    selected=$(_hist_query "search" "" | _read_ns | fzf --height 15 --no-sort --query "$READLINE_LINE")
    
    if [[ -n "$selected" ]]; then
        READLINE_LINE="$selected"
        READLINE_POINT=${#READLINE_LINE}
    fi
}

# Up/Down Stepper
_hist_stepper() {
    local direction="$1"

    if [[ -z "${__hist_index+x}" ]]; then
        __hist_index=0
        __hist_saved_cmd="$READLINE_LINE"
    fi

    if [[ "$direction" == "up" ]]; then
        local offset=$(( __hist_index ))
        local cmd
        cmd=$(_hist_query "up" "$offset" | _read_ns)
        if [[ -n "$cmd" ]]; then
            __hist_index=$(( __hist_index + 1 ))
            READLINE_LINE="$cmd"
            READLINE_POINT=${#READLINE_LINE}
        fi
    elif [[ "$direction" == "down" ]]; then
        if (( __hist_index > 1 )); then
            __hist_index=$(( __hist_index - 1 ))
            local offset=$(( __hist_index - 1 ))
            local cmd
            cmd=$(_hist_query "up" "$offset" | _read_ns)
            if [[ -n "$cmd" ]]; then
                READLINE_LINE="$cmd"
                READLINE_POINT=${#READLINE_LINE}
            fi
        else
            READLINE_LINE="$__hist_saved_cmd"
            READLINE_POINT=${#READLINE_LINE}
            unset __hist_index __hist_saved_cmd
        fi
    fi
}

_hist_stepper_up() { _hist_stepper "up"; }
_hist_stepper_down() { _hist_stepper "down"; }

# Reset State on Execution (Enter Key)
_hist_reset() {
    unset __hist_index __hist_saved_cmd
}

# Cancel State (Ctrl+C)
_hist_cancel() {
    unset __hist_index __hist_saved_cmd
}

# Key Bindings Setup for Modern Bash (bind -x)
_hist_bind_keys() {
    bind -x '"\C-r": _hist_search'
    bind -x '"\e[A": _hist_stepper_up'
    bind -x '"\e[B": _hist_stepper_down'
    
    bind -x '"\C-m": _hist_reset'
    bind -x '"\C-j": _hist_reset'
    bind -x '"\C-c": _hist_cancel'
}

_hist_bind_keys
