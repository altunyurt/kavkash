#!/bin/sh
# t-hooks-zsh.sh — zsh integration: recording + stepper state machine.
# The recording test runs LAST: it adds a row that would otherwise be
# the newest entry the stepper walks.
. "$(dirname "$0")/lib.sh"
sandbox_new
daemon_start

ns_send W "git status" "$PWD" 1000000000000000001 "s1"
sleep 0.1
ns_send W "git push" "$PWD" 1000000000000000002 "s1"
sleep 0.1
ns_send W "ls -la" "$PWD" 1000000000000000003 "s1"
sleep 0.2

zsh_run() { env HOME="$SANDBOX/home" zsh -i -c "$1" 2> /dev/null; }

t_begin "zsh: stepper walks the prefix"
out=$(zsh_run "
    source '$KAVKASH_DIR/functions.zsh'
    _hist_precmd
    BUFFER='git'
    _hist_step_up
    echo \"\$BUFFER|\$_hist_step_idx|\${#_hist_step_cache[@]}\"
")
t_contains "git " "$out" "first match starts with the prefix"
t_contains "|1|2" "$out" "one step, cache holds the git matches"

t_begin "zsh: clearing the line mid-walk resets the offset"
out=$(zsh_run "
    source '$KAVKASH_DIR/functions.zsh'
    _hist_precmd
    BUFFER='git'
    _hist_step_up
    _hist_step_up
    BUFFER=''
    _hist_step_up
    echo \"\$BUFFER|\$_hist_step_idx|\$_hist_step_prefix\"
")
t_eq "ls -la|1|" "$out" "fresh all-history walk from the top"

t_begin "zsh: Down to the bottom restores the typed prefix"
out=$(zsh_run "
    source '$KAVKASH_DIR/functions.zsh'
    _hist_precmd
    BUFFER='git'
    _hist_step_up
    _hist_step_down
    echo \"\$BUFFER|\$_hist_step_idx\"
")
t_eq "git|0" "$out" "typed prefix restored"

t_begin "zsh: preexec/precmd record the command with the real exit code"
zsh_run "
    source '$KAVKASH_DIR/functions.zsh'
    _hist_preexec 'kav zsh probe'
    false
    _hist_precmd
"
sleep 0.3
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code FROM history WHERE command='kav zsh probe';")" "exit code stored"

daemon_stop
t_summary
