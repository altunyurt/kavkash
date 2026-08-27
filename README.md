# kavkash

An Atuin-inspired shell history engine built entirely with SQLite3,
socat, fzf, and POSIX shell scripts.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | dash
```

Installs to `${XDG_DATA_HOME:-~/.local/share}/kavkash`, puts `kavkash` on
PATH via `~/.local/bin/kavkash`. No config file. Overrides (full list in
the installer's header):

- `KAVKASH_IMPORT=1` — import existing bash/zsh/fish history and atuin
  (idempotent, safe to re-run)
- `KAVKASH_NO_SYSTEMD=1` — don't install the systemd unit
- `KAVKASH_REPO` / `KAVKASH_TARBALL_URL` / `KAVKASH_TARBALL_SHA256` — install from elsewhere

## Try it in Docker

```sh
./demo.sh                  # builds a container with the app + YOUR shell
                           # histories copied in; runs the daemon

docker exec -it kavkash-demo bash    # or: fish / zsh
docker stop kavkash-demo
```

`demo.sh` is self-contained and also works piped from the repo:

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/demo.sh | dash
```

`PERSIST=1 ./demo.sh` keeps `history.db` across restarts.

## Run

The installer starts the daemon and prints the exact `source` line for
your shell — it never edits your rc files.

**With systemd** (default when available):

```sh
systemctl --user status kavkash.service     # is it running?
systemctl --user restart kavkash.service    # after an update
journalctl --user -u kavkash.service -f     # logs
```

Without `loginctl enable-linger <user>`, the service stops when you log
out of every session. Daemon messages also go to syslog/journald via
`logger`; `server.log` keeps the raw error stream (capped at 1 MB).

**Without systemd** (`KAVKASH_NO_SYSTEMD=1`, containers, …): start the
daemon once per login session:

```sh
~/.local/share/kavkash/server.sh &
```

**Hook your shell** — one line per shell, then start a new shell:

```sh
# ~/.bashrc
source ~/.local/share/kavkash/functions.bash
# ~/.zshrc
source ~/.local/share/kavkash/functions.zsh
# ~/.config/fish/config.fish
source ~/.local/share/kavkash/functions.fish
```

## Uninstall

```sh
./uninstall.sh              # interactive
./uninstall.sh -y           # non-interactive
./uninstall.sh -y --purge   # also delete stored history
```

Run from the repo (uninstall.sh isn't copied into the install dir).
Stops the daemon, removes runtime files and the install dir; history is
kept unless `--purge`. Rc files are never touched — remove the `source`
line yourself.

## Usage

- **Up / Down** — walk history, no popup. A typed prefix narrows the
  walk (`git ` + Up cycles only `git …` commands).
- **Ctrl+R** — search ALL distinct commands, seeded with the current line.
- **F6** (global) · **F7** (dir + subdirs) · **F8** (this session) —
  scope the search; switch inside the open picker.
- **Enter** runs the picked command; **Tab** pastes it for editing.
- **Shift+Delete** — permanently delete the highlighted command (all
  occurrences, no undo).
- The picker loads ALL distinct commands and filters in-memory (full
  fzf syntax: `^curl` anchors at the command start, `!`, `'exact'`,
  `a|b`, no per-keystroke DB hits). Multi-line commands display
  natively. Each row leads with its last run as `dur ✓/✗ age` (compact
  units: s, m, h, d, w, mo, y) — e.g. `42ms ✗ 3d git push origin main`.
  The metadata never matches — search hits the command only.

## Command line

`kavkash help` lists all commands; `kavkash CMD --help` explains one.

- `status` — daemon up? version, rows/distinct commands, db size
- `info` — install paths, version, revision, shell hooks
- `backup [DIR]` — snapshot (safe while the daemon writes); newest 7
  kept. The daemon also takes one snapshot per day automatically.
- `restore FILE` — stop the daemon, swap FILE in as history.db (the
  current db is kept as `history.db.pre-restore`), start again
- `update` — re-run the installer against the latest release
- `log [N]` — tail the daemon log (default 50 lines)
- `version` — print the installed version
- `history prune` — remove history from the edges (dry run by default;
  `--mean-it` applies). `--oldest=N` / `--newest=N`; `--older-than=WHEN`
  / `--newer-than=WHEN` with a duration (`30d`, `8w`, `2mo`, `45min`,
  `1y` — `2mo` is months, `45min` is minutes) or a strict date; flags
  combine to keep a middle band.
- `history dedup` — collapse repeated commands to one row each (keeps
  the newest; dry run by default). `--all`, `--by-dir[=/PATH]`,
  `--by-date[=DAY]`, `--before/--after=WHEN`.
- `history stats` — totals + the 10 most-used commands
- `history compact` — `PRAGMA integrity_check`, then `VACUUM`
- `history import [ARGS]` — re-import shell/atuin history (idempotent)

Trailing whitespace is trimmed on save; a command starting with
whitespace or `#` is never saved (shell convention, live and imports
alike).

`rm -f ~/.local/share/kavkash/history.db` wipes everything; the daemon
recreates the schema on its next start.

## Requirements

- **fzf ≥ 0.54** — older versions disable the picker and Up/Down
  stepping (warning printed, history still records)
- **socat** (Unix-socket transport), **sqlite3**, **awk** — everything
  else is plain POSIX sh

## Testing

```sh
./tests/run.sh              # native — needs bash/zsh/fish, socat, sqlite3, gawk, fzf
./tests/docker.sh           # hermetic: Debian trixie image, repo mounted read-only
```

Each test file gets a throwaway data/runtime dir with its own daemon —
your real history is never touched. The suite replays every regression
fixed so far; `t-sync.sh` verifies the installed copy matches the repo
(the suite tests the repo, but your shells source the install). CI runs
it on every push.

## How it works

```
shell hooks → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                       ↓
shell Up/Down stepper → query.sh ──────────────────────────────────────┘
shell Ctrl+R/F6-F8 picker ← picker.sh → query.sh ──────────────────────┘
shell picker shift-delete → delete.sh ──────────────────────────────────┘
```

- Shells call `hook.sh` on preexec/precmd (bash synthesizes preexec
  with a DEBUG trap). Messages are netstrings over a Unix socket;
  `server.sh` (socat) hands each connection to `processor.sh` and drops
  connections idle for 5s.
- Rows store the raw command, cwd, exit code, duration, session token.
  The id is ns-since-epoch: INTEGER PRIMARY KEY stores the table in
  time order, so `ORDER BY id DESC` is a reverse leaf scan. WAL mode +
  `synchronous=NORMAL` on writes — a power cut can lose the most recent
  commands (bounded by the ~4MB WAL checkpoint); the file can never
  corrupt.
- Everything on disk is owner-only (0600): the socket, `history.db`
  and its WAL sidecars, `backup.sh` snapshots.
- The picker loads ALL distinct commands via `query.sh` (count=0 = no
  limit) and fzf filters in-memory; the server deduplicates (newest
  occurrence per distinct command) and appends each row's id + last-run
  metadata. Dir/session scope is applied server-side; the scope lives
  in a temp file because fzf transforms run in a subshell.
- Up/Down step through history from an in-shell cache: the first press
  queries a batch of 50 (increasing `OFFSET` over the deduplicated
  set), later presses read from memory. Down never queries.
- `import.sh` — idempotent import from bash/zsh/fish history files and
  atuin (read via the `atuin` CLI — the store layout varies by version
  and v18+ stores are PASETO-encrypted, so the CLI is the only stable
  reader).

## License

MIT — see LICENSE.
