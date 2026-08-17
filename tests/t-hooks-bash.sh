#!/bin/sh
# t-hooks-bash.sh — bash integration: recording + stepper state machine.
# The recording test runs LAST: it adds a row that would otherwise be
# the newest entry the stepper walks.
. "$(dirname "$0")/lib.sh"
sandbox_new
daemon_start

# Seed commands the stepper will walk.
ns_send W "git status" "$PWD" 1000000000000000001 "s1"
sleep 0.1
ns_send W "git push" "$PWD" 1000000000000000002 "s1"
sleep 0.1
ns_send W "ls -la" "$PWD" 1000000000000000003 "s1"
sleep 0.2

bash_run() { env HOME="$SANDBOX/home" bash --norc -i -c "$1" 2> /dev/null; }

t_begin "bash: stepper walks the prefix and cache"
out=$(bash_run "
    source '$KAVKASH_DIR/functions.bash'
    kav_precmd_record
    READLINE_LINE='git'
    _hist_step_up
    echo \"\$READLINE_LINE|\$_hist_step_idx|\${#_hist_step_cache[@]}\"
")
t_contains "git " "$out" "first match starts with the prefix"
t_contains "|1|2" "$out" "one step, cache holds the git matches"

t_begin "bash: repeated Up continues the same walk"
out=$(bash_run "
    source '$KAVKASH_DIR/functions.bash'
    kav_precmd_record
    READLINE_LINE='git'
    _hist_step_up
    _hist_step_up
    echo \"\$READLINE_LINE|\$_hist_step_idx\"
")
t_eq "git status|2" "$out" "two steps back, older match"

t_begin "bash: clearing the line mid-walk resets the offset"
out=$(bash_run "
    source '$KAVKASH_DIR/functions.bash'
    kav_precmd_record
    READLINE_LINE='git'
    _hist_step_up
    _hist_step_up
    READLINE_LINE=''
    _hist_step_up
    echo \"\$READLINE_LINE|\$_hist_step_idx|\$_hist_step_prefix\"
")
t_eq "ls -la|1|" "$out" "fresh all-history walk from the top"

t_begin "bash: Down to the bottom restores the typed prefix"
out=$(bash_run "
    source '$KAVKASH_DIR/functions.bash'
    kav_precmd_record
    READLINE_LINE='git'
    _hist_step_up
    _hist_step_down
    echo \"\$READLINE_LINE|\$_hist_step_idx\"
")
t_eq "git|0" "$out" "typed prefix restored"

t_begin "bash: blank-line walk is unchanged (regression)"
out=$(bash_run "
    source '$KAVKASH_DIR/functions.bash'
    kav_precmd_record
    READLINE_LINE=''
    _hist_step_up
    echo \"\$READLINE_LINE\"
")
t_contains "ls -la" "$out" "blank Up walks all history"

t_begin "bash: precmd resets the stepper state"
out=$(bash_run "
    source '$KAVKASH_DIR/functions.bash'
    kav_precmd_record
    READLINE_LINE='git'
    _hist_step_up
    kav_precmd_record
    echo \"\$_hist_step_idx|\$_hist_step_prefix|\${#_hist_step_cache[@]}\"
")
t_eq "0||0" "$out" "idx, prefix, cache all reset"

t_begin "bash: preexec/precmd record the command with the real exit code"
bash_run "
    source '$KAVKASH_DIR/functions.bash'
    kav_precmd_record
    history -s 'kav record probe'
    kav_preexec_record
    false
    kav_precmd_record
"
sleep 0.3
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code FROM history WHERE command='kav record probe';")" "exit code stored"

daemon_stop
t_summary
