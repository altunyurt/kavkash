#!/usr/bin/env bash
# Build a kavkash demo image with YOUR shell histories COPIED into it
# (not mounted), then run it. Nothing on the host is installed, read, or
# modified — the copies live only inside the image.
#
# A Dockerfile can only COPY from its build context, so this script
# stages the history files (existing ones only) into a temp dir, writes
# a thin Dockerfile that copies them onto the base image, and builds it.
#
#   ./docker/demo.sh            build + run daemon container, ephemeral store
#   PERSIST=1 ./docker/demo.sh  keep history.db across container restarts
#   IMAGE=kavkash:demo USER_IMAGE=kavkash:demo-user NAME=kav-demo ./docker/demo.sh
set -eu

IMAGE=${IMAGE:-kavkash:demo}
USER_IMAGE=${USER_IMAGE:-kavkash:demo-user}
NAME=${NAME:-kavkash-demo}
PERSIST=${PERSIST:-0}

repo_root=$(cd "$(dirname "$0")/.." && pwd)

# 1. base image: kavkash installed via the documented curl|sh flow
docker build -q -t "$IMAGE" "$repo_root"

# 2. stage existing history files + generate the user-layer Dockerfile
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
printf 'FROM %s\n\n' "$IMAGE" > "$stage/Dockerfile"
add_copy() {
    [ -f "$1" ] || return 0
    cp "$1" "$stage/$(basename "$1")"
    printf 'COPY %s %s\n' "$(basename "$1")" "$2" >> "$stage/Dockerfile"
}
# plaintext atuin stores (v17-) only; encrypted v18+ rows need the atuin
# binary inside the container, so copying the db alone won't import those
add_copy "$HOME/.bash_history"                  /root/.bash_history
add_copy "$HOME/.zsh_history"                   /root/.zsh_history
add_copy "$HOME/.local/share/fish/fish_history" /root/.local/share/fish/fish_history
add_copy "$HOME/.local/share/atuin/history.db"  /root/.local/share/atuin/history.db

echo "kavkash demo: copying existing histories into image ($(grep -c '^COPY' "$stage/Dockerfile") file(s))"
docker build -q -t "$USER_IMAGE" "$stage"

# 3. run it; the entrypoint imports the copied histories, then starts the
#    daemon
mounts=()
[ "$PERSIST" = 1 ] && mounts+=("-v" "kavkash-demo-data:/root/.local/share/kavkash")
docker run --rm -d --name "$NAME" "${mounts[@]}" "$USER_IMAGE"

echo "container '$NAME' is running (kavkash daemon, your history imported from the image)."
echo "  docker exec -it $NAME bash    # or: fish / zsh"
echo "stop:  docker stop $NAME"
echo "rebuild with fresh history:  ./docker/demo.sh   (re-copies + rebuilds the image)"
