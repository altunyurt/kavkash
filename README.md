# kavkash

Minimal shell history daemon. Captures commands via preexec hook, stores in SQLite, serves history queries for interactive navigation.

## Architecture

```
shell preexec → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                  ↓
shell up/down/fzf ← functions.{bash,fish,zsh} ←┘
```

## Components

- **includes.sh** — shared defaults (data location, socket/pid paths)
- **install.sh** — curl-pipe installer (fetches latest stable release from GitHub)
- **server.sh** — socat daemon, listens on Unix socket
- **processor.sh** — parses netstring messages, routes writes/queries
- **import.sh** — imports existing history (bash/zsh/fish, atuin) into the DB
- **hook.sh** — sends commands as netstrings from shell preexec hooks
- **functions.bash** — bash integration (↑↓ history, Ctrl+R fzf)
- **functions.fish** — fish integration (same)
- **functions.zsh** — zsh integration (same)

## Protocol

Netstrings, one field per netstring. Concatenated in a single stream.

- **Write:** `W,cmd,cwd,exit_code,duration`
- **Query up:** `Q,up,offset,count` → returns `count` commands starting at `offset`
- **Query search:** `Q,search,arg,count` → returns all commands (capped at 10k); fzf filters client-side

Example write message: `1:W,17:ls -la /home/user,10:/home/user,1:0,3:100,`

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | dash
```

(Piping to `bash` works too.) The installer fetches the latest stable release
from GitHub and installs it to `${XDG_DATA_HOME:-~/.local/share}/kavkash`.
There is no config file: the data location follows the XDG spec, and the
socket path follows `XDG_RUNTIME_DIR` — identical for the daemon and the
shell integrations everywhere.

On install it offers to import your existing history — bash/zsh/fish history
files and the atuin database. Skip or force with `KAVKASH_IMPORT=0|1`; the
import is idempotent (commands already in the DB are skipped). You can also
run `~/.local/share/kavkash/import.sh` manually any time.

Then:

1. Start the daemon and keep it running across reboots (login shell, service
   manager, …):
   ```sh
   ~/.local/share/kavkash/server.sh &
   ```
2. Hook your shell in its rc file:
   - Bash: `source ~/.local/share/kavkash/functions.bash`
     (requires [bash-preexec](https://github.com/rcaloras/bash-preexec))
   - Fish: `source ~/.local/share/kavkash/functions.fish`
   - Zsh: `source ~/.local/share/kavkash/functions.zsh`

## Dependencies

- `dash` (server scripts)
- `socat` (server and client transport)
- `sqlite3` (storage)
- `fzf` (Ctrl+R search)
- `awk` (netstring parser)

## License

See LICENSE.
