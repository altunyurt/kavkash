#!/bin/sh
# t-import.sh — fixture imports: bash/zsh/fish, whitespace skip, idempotency.
. "$(dirname "$0")/lib.sh"
sandbox_new

# bash fixture: plain lines + a leading-space and a leading-tab line.
printf 'echo plain one\necho leading space\necho leading tab\n' > "$SANDBOX/hist"
sed -i '2s/^/ /; 3s/^/\t/' "$SANDBOX/hist"

t_begin "import: bash fixture imports only the plain command"
t_rc 0 "import -b" env HISTFILE="$SANDBOX/hist" "$KAVKASH_DIR/import.sh" -b
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command LIKE 'echo %';")" "leading-space skipped"
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='echo plain one';")" "plain command imported"

t_begin "import: re-running is idempotent"
t_rc 0 "import -b again" env HISTFILE="$SANDBOX/hist" "$KAVKASH_DIR/import.sh" -b
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='echo plain one';")" "no duplicates"

# zsh fixture: ": <epoch>:<dur>;<cmd>" lines.
printf ': 1700000000:0;echo zsh one\n: 1700000001:0; echo zsh hidden\n' > "$SANDBOX/zhist"
t_begin "import: zsh fixture keeps timestamps, skips leading space"
t_rc 0 "import -z" env HISTFILE="$SANDBOX/zhist" "$KAVKASH_DIR/import.sh" -z
t_eq "1700000000000000000" "$(kav_db "$KAV_DB_FILE" "SELECT id FROM history WHERE command='echo zsh one';")" "timestamp preserved"
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='echo zsh hidden';")" "leading space skipped"

# fish fixture: fish_history YAML.
mkdir -p "$XDG_DATA_HOME/fish"
printf -- '- cmd: echo fish one\n  when: 1700000000\n- cmd: " echo fish hidden"\n  when: 1700000001\n- cmd: # fish comment\n  when: 1700000002\n' > "$XDG_DATA_HOME/fish/fish_history"
t_begin "import: fish fixture imports, skips leading space and # comments"
t_rc 0 "import -f" "$KAVKASH_DIR/import.sh" -f
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='echo fish one';")" "fish command imported"
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='echo fish hidden';")" "leading space skipped"
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='# fish comment';")" "# comment skipped"

t_summary
