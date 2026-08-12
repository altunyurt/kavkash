# kavkash

An Atuin inspired shell history engine entirely built with SQLite3, socat, fzf, and POSIX shell scripts. 

Built with *extensive* LLM assistance, battle-tested in daily use.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | dash
```

Installs to `${XDG_DATA_HOME:-~/.local/share}/kavkash` (Unix socket under
`XDG_RUNTIME_DIR`). No config file. Useful overrides (full list in the
installer's header):

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
                           # curl|sh install), copies your histories in,
                           # runs the daemon container

docker exec -it kavkash-demo bash    # or: fish / zsh — any shell works
docker stop kavkash-demo
```

`demo.sh` is a single self-contained file — it generates the Dockerfile
and the container entrypoint at run time, so it also works piped
straight from the repo, exactly like the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/demo.sh | dash
```

It copies your existing shell history files (bash, zsh, fish — only the
ones that exist) into the image; the entrypoint imports them into
`history.db` at container start (idempotent). Your **atuin store is
mounted read-only instead** (real db path from atuin's own config /
`atuin info`): atuin records nothing inside the container, so the ro
mount can't be tainted, and the key file stays on the host — baking it
into an image would leak a secret through the immutable layers. Import
goes through the `atuin` CLI — the image ships the exact version your
host runs (stores carry a schema version, so a mismatched binary would
either refuse to open them or try to migrate the ro mount), decrypting
v18+ stores with the mounted key. Re-run it any time to rebuild with
fresh history.
`PERSIST=1 ./demo.sh` keeps `history.db` across restarts (volume
`kavkash-demo-data`). The image installs
kavkash with the exact one-liner the README documents —
`curl -fsSL …/install.sh | dash` — resolving the latest GitHub release
and verifying its checksum at build time. The rc files are wired at
build, so every exec'd shell is a kavkash session automatically. Base is
Debian 13 pinned — kavkash needs fzf ≥ 0.54, and bookworm's 0.38 would
silently disable the picker.

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

- **Up** (`walk> `) — browse the 500 newest commands.
- **Ctrl+R** (`search> `) — search everything, seeded with the current
  line (cap 10k).
- **F6** (`all> `) · **F7** (`dir> `) · **F8** (`sess> `) — scope the
  search: global, current dir + subdirs, or this shell session. They
  switch scope inside the open picker (prompt updates, list reloads,
  query kept).
- **Enter** runs the picked command; **Tab** pastes it onto the line for
  editing.
- The picker loads a window of the newest commands and filters it
  in-memory — full fzf syntax (`!`, `'exact'`, `a|b`), no per-keystroke
  DB hits. The window doubles automatically when exhausted; **F5**
  forces the next page. Multi-line commands display natively.
- On bash ≥ 4.3, Enter runs through readline's native `accept-line`
  (atuin's macro-chain trick), so the command behaves exactly as typed —
  real exit code and duration are recorded. Older bash and ble.sh use a
  print+eval fallback.

## Requirements

- **fzf ≥ 0.54** — older versions disable the picker (warning printed,
  history still records)
- **socat** (Unix-socket transport; `nc -U` works as fallback),
  **sqlite3**, **awk** — everything else is plain POSIX sh

Developed and tested on Debian trixie (dash, bash 5.2, zsh, fish 4).

## How it works

```
shell hooks → hook.sh → Unix socket → server.sh → processor.sh → SQLite
                                                                    ↓
shell Up/Ctrl+R fzf picker ← picker.sh → query.sh ←──────────────────┘
```

- Shells call `hook.sh` on preexec/precmd (bash synthesizes preexec with
  a DEBUG trap; the precmd fire catches lines the trap can't see, e.g.
  function definitions). Messages are netstrings (`len:payload,`) over a
  Unix socket; `server.sh` (socat) hands each connection to
  `processor.sh`.
- Each row stores the raw command (multi-line safe), cwd, exit code,
  duration, and a per-shell session token. The row id is ns-since-epoch:
  INTEGER PRIMARY KEY aliases the rowid, so the table is stored in time
  order and `ORDER BY id DESC` is a reverse leaf scan.
- The picker (`functions.*`) loads a *window* of the newest commands via
  `query.sh` and fzf filters it in-memory. Dir/session scope is filtered
  server-side **before** the LIMIT, so an old scoped command isn't cut
  off by the window. `picker.sh` drives pagination from fzf events; win
  size and scope live in temp files because fzf transforms run in a
  subshell.
- `import.sh` — idempotent import from bash/zsh/fish history files and
  atuin (read via the `atuin` CLI: the store layout varies by version
  and v18+ stores are PASETO-encrypted, so the CLI is the only stable
  reader — it decrypts with your key).

## Pruning

History grows without bound. Keep the newest N commands and reclaim the
space:

```sh
sqlite3 ~/.local/share/kavkash/history.db \
  "DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY id DESC LIMIT 5000); VACUUM;"
```

`rm -f ~/.local/share/kavkash/history.db` wipes everything; the daemon
recreates the schema on its next start.

## License

MIT — see LICENSE.
