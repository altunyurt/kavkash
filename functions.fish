# kavkash fish integration — source from config.fish.
# Socket path must match includes.sh: ${XDG_RUNTIME_DIR}/kavkash/history.sock.
# fish cannot source includes.sh (POSIX sh syntax), so these stay duplicated
# — keep in sync.
if set -q XDG_RUNTIME_DIR
    set -g _HIST_SOCK "$XDG_RUNTIME_DIR/kavkash/history.sock"
else
    set -g _HIST_SOCK "/tmp/kavkash/history.sock"
end
# Directory containing this file (project root); hook.sh/query.sh live here.
# Resolved to a REAL path: fish refuses to exec command paths containing "..".
set -g _HIST_SCRIPT_DIR (dirname (status filename))
set -g _HIST_HOOK (realpath "$_HIST_SCRIPT_DIR/hook.sh")

# _hist_picker — the single fzf widget behind both Up and Ctrl+R (see
# functions.bash for the design rationale). Accept: Enter runs the picked
# command, Tab pastes it onto the line.
function _hist_picker
    set -l count $argv[1]
    set -l init_q $argv[2]
    # NOTE: fzf's stderr must stay connected to the terminal. Inside a
    # command substitution stdout is a pipe, so fzf falls back to stderr
    # (then /dev/tty) for its UI — a `2>/dev/null` here makes the picker
    # render nothing and appear stuck.
    # read -z: NUL-delimited capture. Fish variables can't hold NUL, so the
    # selection must NOT go through command substitution. --expect=tab
    # prefixes the output with the accepting key ("tab" or empty for Enter);
    # the awk turns that into "key\n<decoded command>" for the shell to
    # split, reversing the server's \n / \\ display escaping.
    set -l picked
    "$_HIST_SCRIPT_DIR/query.sh" "$count" "$init_q" | fzf \
        --disabled --height 15 --no-sort --prompt 'history> ' \
        --query "$init_q" --read0 --print0 --expect=tab \
        --bind "change:reload:sleep 0.1; $_HIST_SCRIPT_DIR/query.sh $count {q}" \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 {
                s = $0; o = ""; n = length(s); i = 1
                while (i <= n) {
                    c = substr(s, i, 1)
                    if (c == "\\\\" && i < n) {
                        c2 = substr(s, i + 1, 1)
                        if (c2 == "\\\\") { o = o "\\\\"; i += 2; continue }
                        if (c2 == "n")  { o = o "\n"; i += 2; continue }
                    }
                    o = o c; i++
                }
                printf "%s\n%s\n", key, o
            }' | read -z picked
    test -n "$picked"; or return 0
    set -l key (printf '%s' "$picked" | head -n1)
    set -l cmd
    printf '%s' "$picked" | sed '1d' | read -z cmd
    test -n "$cmd"; or return 0
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

# Apply bindings now: fish only auto-calls fish_user_key_bindings at startup,
# so a mid-session `source functions.fish` would otherwise never bind.
fish_user_key_bindings

