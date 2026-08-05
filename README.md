# kavkash

Minimal shell history daemon. Captures commands via shell hooks (preexec
for fish/zsh, precmd+history for bash), stores in SQLite, serves history
queries for interactive navigation.

## Architecture

```
shell hooks → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                    ↓
shell up/Ctrl+R fzf picker ← picker.sh → query.sh ←──────────────────┘
```

## Components

- **includes.sh** — shared defaults (data location, socket/pid paths) and the
  UUIDv7 id builder
- **install.sh** — curl-pipe installer (fetches latest stable release from GitHub)
- **server.sh** — socat daemon, listens on Unix socket
- **processor.sh** — parses netstring messages, routes writes/queries
- **import.sh** — imports existing history (bash/zsh/fish, atuin) into the DB
- **hook.sh** — sends commands as netstrings from shell preexec hooks
- **query.sh** — fzf picker back-end (sockets the daemon; serves the picker's
  paginated result windows)
- **picker.sh** — fzf event-driven pagination helper: grows the picker's
  window via `reload-sync` actions when the loaded window is exhausted (or on
  F5)
- **functions.bash** — bash integration (Up/Ctrl+R fzf picker)
- **functions.fish** — fish integration (same)
- **functions.zsh** — zsh integration (same)

## Navigation

Up and Ctrl+R both open the fzf picker, distinguished by prompt and header:

- **Up** (`walk> `) — browse the 500 newest commands, empty query.
- **Ctrl+R** (`search> `) — full-text search, seeded with the current line,
  capped at 10k.

The picker loads a *window* of the newest commands (min(cap, 1000)) through
`start:reload-sync` — a single code path, no initial pipe — and fzf filters
it in-memory as you type. No per-keystroke database round trips, and the
full fzf search syntax works (`!` exclusions, `'exact'` terms, `a|b`). When
the window is exhausted — every loaded command matches, or none do — a
`result`-event `transform` doubles the window up to the per-widget cap
(picker.sh); **F5** forces the next page. `--sync` resolves the initial
cascade before the first paint, so a seeded Ctrl+R query reaches full
coverage in a few log₂-sized round trips, and `--track` keeps the cursor on
the current command across reloads.

Accept: **Enter** picks and runs the command (zsh/fish accept the line
from the widget; bash records it with `history -s` and runs it directly —
readline widgets can't accept the line). **Tab** picks and pastes the
command onto the line without running it, ready to edit. Multi-line
commands display natively on multiple lines (fzf ≥ 0.53); command text
passes through verbatim — the old `\n`/`\\` display escaping is gone.

## Protocol

Netstrings, one field per netstring. Concatenated in a single stream.

- **Write:** `W,cmd,cwd,id` — sent by the shell's preexec hook when a
  command starts (fish/zsh), or by bash's precmd hook after it ran.
  (bash: the DEBUG-trap-based preexec can't see function-definition
  commands, so bash reads `history 1` in precmd instead — duration is 0
  there, and `exit`/leading-space commands aren't captured). `id` is a
  UUIDv7 minted by hook.sh: it is the row's primary key **and** its
  timestamp (lexicographic id order == chronological order), so no
  separate timestamp column exists. Exit code and duration arrive via
  Update.
- **Update:** `U,id,exit_code,duration_ms` — sent by the shell's precmd hook
  when the command finishes; the shell measured the duration between
  preexec and precmd (0 in bash). UUIDs are never reused, so stale keys
  are impossible and nothing needs clearing.
- **Query:** `Q,search,query,count` → returns up to `count` commands whose
  text subsequence-matches every term of `query` (empty query = newest
  `count`; the picker pages unfiltered windows, so it always sends an empty
  query and fzf's own matcher does the filtering — the server-side
  subsequence builder is legacy). Rows are raw commands, NUL-terminated
  (command text can never contain NUL, so the framing is unambiguous);
  fzf consumes them via `--read0`/`--print0` and displays multi-line
  commands natively. The sqlite3 framing hazards 0x1E/0x1F plus `\r` are
  stripped server-side.

Example write message: `1:W,2:ls,10:/home/user,36:018f2a3b-1c2d-7000-8000-9a8b7c6d5e4f,`

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
- `fzf` ≥ 0.54 (Ctrl+R search; the picker uses `transform`, `result` events,
  `start:reload`, multi-line display, and the `--sync` render guarantee)
- `awk` (netstring parser)

## License

See LICENSE.
