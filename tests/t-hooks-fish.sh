#!/bin/sh
# t-hooks-fish.sh — fish integration: recording (headless) + stepper (pty).
. "$(dirname "$0")/lib.sh"
sandbox_new
daemon_start

ns_send W "git status" "$PWD" 1000000000000000001 "s1"
sleep 0.2

t_begin "fish: preexec/postexec record the command with the real exit code"
env HOME="$SANDBOX/home" fish -c "
    source '$KAVKASH_DIR/functions.fish'
    _hist_preexec 'kav fish probe'
    false
    _hist_postexec
" 2> /dev/null
sleep 0.3
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code FROM history WHERE command='kav fish probe';")" "exit code stored"

t_begin "fish: stepper fills the cache under a pty"
out=$(script -qec "fish -i -c 'source $KAVKASH_DIR/functions.fish; _hist_step_up; echo CACHE_(count \$_kav_step_cache)'" /dev/null 2> /dev/null)
t_contains "CACHE_2" "$out" "cache holds the two seeded rows"

# A multi-line command as the newest row: (commandline -b) splits the
# buffer per line, so a first-line-only comparison used to reset the
# walk on every press — the stepper re-showed the same command forever.
t_begin "fish: stepper walks past a multi-line command"
ml=$(printf 'function greet\n    echo hi\nend')
ns_send W "$ml" "$PWD" 9999999999999999990 "s1"
sleep 0.2
out=$(script -qec "fish -i -c 'source $KAVKASH_DIR/functions.fish; _hist_step_up; _hist_step_up; echo IDX_\$_kav_step_idx'" /dev/null 2> /dev/null)
t_contains "IDX_2" "$out" "two presses advance past the multi-line row (no reset loop)"

daemon_stop
t_summary
