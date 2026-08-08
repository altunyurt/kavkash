# kavkash

Minimal shell history daemon. Commands are captured through shell hooks into
SQLite and served back via an fzf picker — **Up** browses the recent ones,
**Ctrl+R** searches everything.

## Architecture

```
shell hooks → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                    ↓
shell Up/Ctrl+R fzf picker ← picker.sh → query.sh ←──────────────────┘
```

## Components

- **includes.sh** — shared XDG paths, the ns-since-epoch id builder, schema creation/migration
- **hook.sh** — mints ids, sends `W`/`U` messages from shell hooks
- **server.sh** — socat daemon on the Unix socket
- **processor.sh** — netstring parser, message routing, SQLite
- **query.sh** — serves NUL-framed result rows to the picker
- **picker.sh** — paginates the picker's window (grows on exhaustion, F5 forces)
- **import.sh** — imports bash/zsh/fish/atuin history
- **install.sh**, **uninstall.sh** — install and remove
- **functions.{bash,zsh,fish}** — the Up/Ctrl+R picker per shell

## Navigation

- **Up** (`walk> `) — browse the 500 newest commands.
- **Ctrl+R** (`search> `) — search everything, seeded with the current line
  (cap 10k).

The picker shows a window of the newest commands and filters it in-memory as
you type — full fzf syntax (`!`, `'exact'`, `a|b`), no per-keystroke DB
queries. When the loaded window is exhausted it doubles automatically (up to
the cap); **F5** forces the next page. **Enter** runs the picked command,
**Tab** pastes it onto the line for editing. Multi-line commands display
natively.

## Protocol

Netstrings (`len:payload,`), one field per netstring, over the Unix socket.

- **W** `cmd,cwd,id` — command started. `id` is ns-since-epoch: the row's
  primary key *and* timestamp (INTEGER PRIMARY KEY = rowid, so the table
  is stored in time order). fish/zsh fire this in
  preexec; bash synthesizes one with a DEBUG trap, plus a fire on the
  prompt itself that catches lines the trap can't see directly (function
  definitions are recorded there, with exit code and duration). `exit` is
  delivered synchronously so the last command isn't lost. Leading-space
  commands never reach bash history (HISTCONTROL=ignorespace) and are
  missed.
- **U** `id,exit_code,duration_ms` — command finished; fills in exit code
  and duration (real in all shells; 0 only when the completion update is
  lost to a race or the line was fallback-captured).
- **Q** `search,query,count` — newest `count` commands, NUL-framed raw rows
  (multi-line safe; 0x1E/0x1F/`\r` stripped). The picker sends an empty
  query and fzf filters in-memory — the server-side subsequence matcher
  was removed; the query field is ignored.

Example: `1:W,2:ls,10:/home/user,19:1786230239695766534,`

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | dash
```

Installs to `${XDG_DATA_HOME:-~/.local/share}/kavkash` (socket under
`XDG_RUNTIME_DIR`); no config file. The installer offers to import existing
history (bash/zsh/fish, atuin ≥ v18 via its CLI) — `KAVKASH_IMPORT=0|1`
skips/forces. Import is idempotent — safe to re-run: rows deduplicate
on (command, cwd, timestamp), while the same command at different times
is kept.

1. Start the daemon once (login shell, service manager, …):
   ```sh
   ~/.local/share/kavkash/server.sh &
   ```
2. Source the integration in your rc file:
   ```sh
   source ~/.local/share/kavkash/functions.bash
   source ~/.local/share/kavkash/functions.fish
   source ~/.local/share/kavkash/functions.zsh
   ```

## Requirements

| dependency  | minimum      | notes                                        |
|-------------|--------------|----------------------------------------------|
| fzf         | 0.54         | enforced — older versions disable the picker (warning printed, shell defaults kept) |
| socat       | 1.7          | Unix-socket transport; `nc -U` works as fallback |
| sqlite3     | 3.x          | storage                                      |
| awk         | mawk 1.3.4 / gawk | netstring parsing, query building       |
| dash        | any          | scripts are plain POSIX sh                   |

## Compatibility

Developed and tested on **Debian GNU/Linux 13 (trixie)** with dash 0.5.12,
socat 1.8.0.3, sqlite3 3.46.1, mawk 1.3.4, fzf 0.60, bash 5.2, zsh 5.9 and
fish 4.0.2. Any Linux with the dependencies above should work.

## Pruning

History grows without bound. Keep the newest N commands (id order == time
order) and reclaim the space:

```sh
sqlite3 ~/.local/share/kavkash/history.db \
  "DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY id DESC LIMIT 5000); VACUUM;"
```

`rm -f ~/.local/share/kavkash/history.db` wipes everything; the daemon
recreates the schema on next start.

## License

MIT — see LICENSE.
