# kavkash

Minimal shell history daemon. Captures commands via preexec hook, stores in SQLite, serves history queries for interactive navigation.

## Architecture

```
shell preexec → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                  ↓
shell up/down/fzf ← shells/{bash,fish,zsh}/functions.{bash,fish,zsh} ←┘
```

## Components

- **includes.sh** — shared defaults (data location, socket/pid paths)
- **install.sh** — curl-pipe installer (fetches latest stable release from GitHub)
- **server.sh** — socat daemon, listens on Unix socket
- **processor.sh** — parses netstring messages, routes writes/queries
- **hook.sh** — sends commands as netstrings from shell preexec hooks
- **shells/bash/functions.bash** — bash integration (↑↓ history, Ctrl+R fzf)
- **shells/fish/functions.fish** — fish integration (same)
- **shells/zsh/functions.zsh** — zsh integration (same)

## Protocol

Netstrings, one field per netstring. Concatenated in a single stream.

- **Write:** `W,cmd,cwd,exit_code,duration`
- **Query up:** `Q,up,offset,count` → returns `count` commands starting at `offset`
- **Query search:** `Q,search,arg,count` → returns matching commands

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

Then:

1. Start the daemon and keep it running across reboots (login shell, service
   manager, …):
   ```sh
   ~/.local/share/kavkash/server.sh &
   ```
2. Hook your shell in its rc file:
   - Bash: `source ~/.local/share/kavkash/shells/bash/functions.bash`
     (requires [bash-preexec](https://github.com/rcaloras/bash-preexec))
   - Fish: `source ~/.local/share/kavkash/shells/fish/functions.fish`
   - Zsh: `source ~/.local/share/kavkash/shells/zsh/functions.zsh`

## Dependencies

- `dash` (server scripts)
- `socat` (server and client transport)
- `sqlite3` (storage)
- `fzf` (Ctrl+R search)
- `awk` (netstring parser)

## License

See LICENSE.
