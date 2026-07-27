# kavkash

Minimal shell history daemon. Captures commands via preexec hook, stores in SQLite, serves history queries for interactive navigation.

## Architecture

```
shell preexec → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                  ↓
shell up/down/fzf ← shells/{bash,fish}/functions.{bash,fish} ←────┘
```

## Components

- **server.sh** — socat daemon, listens on Unix socket
- **processor.sh** — parses netstring messages, routes writes/queries
- **hook.sh** — sends commands as netstrings from shell preexec hooks
- **shells/bash/functions.bash** — bash integration (↑↓ history, Ctrl+R fzf)
- **shells/fish/functions.fish** — fish integration (same)

## Protocol

Netstrings, one field per netstring. Concatenated in a single stream.

- **Write:** `W,cmd,cwd,exit_code,duration`
- **Query up:** `Q,up,offset,count` → returns `count` commands starting at `offset`
- **Query search:** `Q,search,arg,count` → returns matching commands

Example write message: `1:W,17:ls -la /home/user,10:/home/user,1:0,3:100,`

## Installation

1. Copy `server.sh`, `processor.sh`, `hook.sh` to `~/.local/share/kavkash/`
2. Source the appropriate shell file in your rc:
   - Bash: `source ~/.local/share/kavkash/shells/bash/functions.bash`
   - Fish: `source ~/.local/share/kavkash/shells/fish/functions.fish`
3. Add preexec hook (bash example):
   ```bash
   __kavkash_preexec() { __kavkash_cmd="$BASH_COMMAND"; __kavkash_start=$(date +%s%3N); }
   trap '__kavkash_preexec' DEBUG
   __kavkash_postexec() {
       local d=$(( $(date +%s%3N) - ${__kavkash_start:-0} ))
       ~/.local/share/kavkash/hook.sh "$__kavkash_cmd" "$PWD" "$?" "$d" &
   }
   trap '__kavkash_postexec' EXIT
   ```
4. Start server: `dash ~/.local/share/kavkash/server.sh &`

## Dependencies

- `dash` (server scripts)
- `socat` (server and client transport)
- `sqlite3` (storage)
- `fzf` (Ctrl+R search)
- `awk` (netstring parser)

## License

See LICENSE.
