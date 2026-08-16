# kavkash

An Atuin inspired shell history engine entirely built with SQLite3, socat, fzf, and POSIX shell scripts. 

Built with *extensive* LLM assistance, battle-tested in daily use.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | dash
```

Installs to `${XDG_DATA_HOME:-~/.local/share}/kavkash` (Unix socket under
`XDG_RUNTIME_DIR`) and puts `kavkash` on PATH via a symlink at
`~/.local/bin/kavkash` (keep `~/.local/bin` on your PATH). No config
file. Useful overrides (full list in the installer's header):

- `KAVKASH_IMPORT=1` — import existing bash/zsh/fish history and atuin
  (atuin history is read via the `atuin` CLI — the store layout varies
  by version and v18+ stores are PASETO-encrypted, so the CLI is the
  only stable reader, resolving the store and your key itself);
  re-running the import is idempotent and safe
- `KAVKASH_NO_SYSTEMD=1` — don't install the systemd unit
- `KAVKASH_REPO` / `KAVKASH_TARBALL_URL` / `KAVKASH_TARBALL_SHA256` — install from elsewhere

## Try it in Docker (nothing touches your system)

A container with the whole app — daemon, shell hooks, fzf picker — with
**your** shell histories copied into the image (bash/zsh/fish files; the
atuin store and key are mounted read-only instead — see below). No
install, no rc edits — nothing is written to the host.

```sh
./demo.sh                  # builds the image (kavkash via the real
                           # curl|sh install), copies your shell histories
                           # in, runs the daemon container

docker exec -it kavkash-demo bash    # or: fish / zsh — any shell works
docker stop kavkash-demo
```

`demo.sh` is a single self-contained file — it generates the Dockerfile
and the container entrypoint at run time, so it also works piped
straight from the repo, exactly like the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/demo.sh | dash
```

To import your history, demo.sh copies the history files of your shell(s) 
into the image and mounts the atuin store as readonly, without breaking or 
tainting your existing setup.

`PERSIST=1 ./demo.sh` keeps `history.db` across restarts (volume
`kavkash-demo-data`). 


## Run

The installer starts the daemon and prints the exact `source` line for
your shell — it never edits your rc files.

**With systemd** (default when available): a `kavkash.service` user unit
is enabled and started (`Restart=on-abnormal`, starts at login). Manage
it like any user service:

```sh
systemctl --user status kavkash.service     # is it running?
systemctl --user restart kavkash.service    # after an update
journalctl --user -u kavkash.service -f     # logs
```

Note: without `loginctl enable-linger <user>`, the service stops when
you log out of every session.

**Without systemd** (`KAVKASH_NO_SYSTEMD=1`, containers, …): start the
daemon once per login session:

```sh
~/.local/share/kavkash/server.sh &
```

**Hook your shell** — add one line to your rc file, then start a new
shell:

```sh
# ~/.bashrc
source ~/.local/share/kavkash/functions.bash
# ~/.zshrc
source ~/.local/share/kavkash/functions.zsh
# ~/.config/fish/config.fish
source ~/.local/share/kavkash/functions.fish
```

## Uninstall

Run `uninstall.sh` from the kavkash repo (it isn't copied into the
install dir):

```sh
./uninstall.sh              # interactive
./uninstall.sh -y           # non-interactive
./uninstall.sh -y --purge   # also delete stored history
```

It stops the daemon (systemd unit or pid-file), removes runtime files
and the install dir. Stored history is kept unless `--purge`; your rc
files are never touched — remove the `source` line yourself.

## Usage

- **Up / Down** — walk history back and forth, no popup. A typed
  prefix narrows the walk: `git ` + Up cycles only `git …` commands,
  more Ups go further back, Down steps forward and returns to what you
  typed. An empty line walks everything.
- **Ctrl+R** (`all> `) — where the real thing begins: search ALL
  distinct commands, seeded with the current line.
- **F6** (`all> `) · **F7** (`dir> `) · **F8** (`sess> `) — scope the
  search: global, current dir + subdirs, or this shell session. They
  switch scope inside the open picker (prompt updates, list reloads,
  query kept).
- **Enter** runs the picked command; **Tab** pastes it onto the line for
  editing.
- **Shift+Delete** — permanently delete the highlighted command (all its
  occurrences; no undo).
- The picker loads ALL distinct commands (each command appears once —
  hundreds of `ls` become a single entry) and filters them in-memory —
  full fzf syntax (`!`, `'exact'`, `a|b`), no per-keystroke DB hits.
  Multi-line commands display natively.

## Command line

`kavkash` is the dispatcher for everything outside the shells —
`kavkash help` lists all commands, `kavkash CMD --help` explains one.

- `kavkash status` — daemon up? version, rows/distinct commands, db size
- `kavkash info` — install paths (data/db/socket/pid/log), version, revision, shell hooks
- `kavkash backup [DIR]` — snapshot history.db (safe while the daemon
  writes); named `history.db.TIMESTAMP` in DIR (default the data dir),
  newest 7 kept. The daemon also takes one snapshot per day
  automatically — on its first recorded command of the day and at boot.
- `kavkash restore FILE` — stop the daemon, swap FILE in as history.db
  (the current db is kept as `history.db.pre-restore`), start again
- `kavkash update` — re-run the installer against the latest release
- `kavkash log [N]` — tail the daemon log (default 50 lines)
- `kavkash version` — print the installed version
- `kavkash history ...` — operations on the stored history:

  - **`history prune`** — remove history from the edges. Dry run by
    default (shows what would be removed, changes nothing);
    `--mean-it` applies it.
    - `--oldest=N` / `--newest=N` — remove the N oldest / newest commands
    - `--older-than=WHEN` / `--newer-than=WHEN` — remove everything older /
      newer than WHEN: a duration (`30d`, `8w`, `2mo`, `45min`, `1y` —
      `2mo` is months, `45min` is minutes) or a date (`2026-06-01`,
      `yesterday`); future boundaries are refused
    - flags combine — `prune --older-than=90d --newer-than=7d --mean-it`
      removes both ends, keeping the middle band
  - **`history dedup`** — collapse repeated commands to one row each
    (keeps the newest occurrence). Dry run by default; `--mean-it`
    applies it.
    - `--all` — the whole table by command (exclusive with the rest)
    - `--by-dir[=/PATH]` — also group by directory; with a value, only
      commands in that cwd (repeatable)
    - `--by-date[=DAY]` — also group by calendar day; with a value, only
      that day
    - `--before=WHEN` / `--after=WHEN` — only rows before / after WHEN
      (mutually exclusive with `--by-date`)
  - **`history stats`** — totals + the 10 most-used commands
  - **`history compact`** — `PRAGMA integrity_check`, then `VACUUM`
  - **`history import [ARGS]`** — re-import shell/atuin history
    (idempotent; `--all` imports everything)

Trailing whitespace on commands is trimmed on save — `ls ` and `ls`
are the same command, and dedup folds any old variants. A command
starting with whitespace is never saved (the shell convention —
`HISTCONTROL=ignorespace` / fish's built-in skip), in live recording
and in imports alike.

`rm -f ~/.local/share/kavkash/history.db` wipes everything; the daemon
recreates the schema on its next start.

## Requirements

- **fzf ≥ 0.54** — older versions disable the picker and Up/Down
  stepping (warning printed, history still records)
- **socat** (Unix-socket transport; `nc -U` works as fallback),
  **sqlite3**, **awk** — everything else is plain POSIX sh

Developed and tested on Debian trixie (dash, bash 5.2, zsh, fish 4).

## How it works

```
shell hooks → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                       ↓
shell Up/Down stepper → query.sh ──────────────────────────────────────┘
shell Ctrl+R/F6-F8 picker ← picker.sh → query.sh ──────────────────────┘
shell picker shift-delete → delete.sh ──────────────────────────────────┘
```

- Shells call `hook.sh` on preexec/precmd (bash synthesizes preexec with
  a DEBUG trap; the precmd fire catches lines the trap can't see, e.g.
  function definitions). Messages are netstrings (`len:payload,`) over a
  Unix socket; `server.sh` (socat) hands each connection to
  `processor.sh`.
- Each row stores the raw command (multi-line safe), cwd, exit code,
  duration, and a per-shell session token. The row id is ns-since-epoch:
  INTEGER PRIMARY KEY aliases the rowid, so the table is stored in time
  order and `ORDER BY id DESC` is a reverse leaf scan. The database runs
  in WAL mode, so readers never block the daemon's writes.
- The picker (`functions.*`) loads ALL distinct commands via `query.sh`
  (count=0 = no limit) and fzf filters them in-memory. The server
  deduplicates (GROUP BY command, newest occurrence first) and appends
  each row's id to the payload — hidden from the display, but Shift+Delete
  hands it to `delete.sh`, which removes every occurrence of the command
  via the `D` action, then reloads. Dir/session scope is applied
  server-side, so a scope switch (F6-F8) re-queries the whole scoped set.
  The scope lives in a temp file because fzf transforms run in a subshell.
- Up/Down step through all of history one distinct command per press,
  served from an in-shell cache: the first press queries a batch of 50
  (increasing `OFFSET` over the deduplicated set — cheap, since the
  rowid index makes the OFFSET scan a reverse leaf walk) and later
  presses read from memory. Down never queries; the cache resets at
  every prompt.
- `import.sh` — idempotent import from bash/zsh/fish history files and
  atuin (read via the `atuin` CLI: the store layout varies by version
  and v18+ stores are PASETO-encrypted, so the CLI is the only stable
  reader — it decrypts with your key).

## License

MIT — see LICENSE.
