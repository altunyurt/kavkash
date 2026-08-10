#!/usr/bin/env bash
# Launch a kavkash demo container that imports YOUR shell histories
# read-only — nothing on the host is installed, read, or modified.
#
#   ./docker/demo.sh            daemon container, ephemeral store
#   PERSIST=1 ./docker/demo.sh  keep history.db across container restarts
#   IMAGE=kavkash:demo NAME=kav-demo ./docker/demo.sh
set -eu

IMAGE=${IMAGE:-kavkash:demo}
NAME=${NAME:-kavkash-demo}
PERSIST=${PERSIST:-0}

mounts=()
add_mount() { [ -f "$1" ] && mounts+=("-v" "$1:$2:ro"); }
add_mount "$HOME/.bash_history"                  /root/.bash_history
add_mount "$HOME/.zsh_history"                   /root/.zsh_history
add_mount "$HOME/.local/share/fish/fish_history" /root/.local/share/fish/fish_history
# plaintext atuin stores (v17-); encrypted v18+ needs the atuin binary
# inside the container, so the mount alone won't import those
add_mount "$HOME/.local/share/atuin/history.db"  /root/.local/share/atuin/history.db
[ "$PERSIST" = 1 ] && mounts+=("-v" "kavkash-demo-data:/root/.local/share/kavkash")

echo "kavkash demo: mounting ${#mounts[@]} history file(s) read-only"
docker run --rm -d --name "$NAME" "${mounts[@]}" "$IMAGE"

echo "container '$NAME' is running (kavkash daemon). Attach a shell:"
echo "  docker exec -it $NAME bash    # or: fish / zsh"
echo "stop:  docker stop $NAME"
