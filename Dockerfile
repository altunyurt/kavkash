# kavkash demo image: the whole app (daemon + shell hooks + fzf picker) in
# an isolated container, so you can try it on your own history without
# installing anything on the host.
#
# Base pinned to Debian 13 (trixie): kavkash needs fzf >= 0.54 (older fzf
# can't render the multi-line rows the server sends — the picker is
# silently disabled). Trixie ships fzf 0.60; bookworm ships 0.38, so
# `stable` would break this image silently.
FROM debian:13-slim

# Runtime deps: socat (socket daemon), sqlite3 (store), mawk (processor),
# fzf (picker), the three shells the hooks integrate with, and curl
# (install.sh's downloader — also lets you run the curl|sh flow inside).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash zsh fish \
        socat sqlite3 mawk fzf curl \
 && rm -rf /var/lib/apt/lists/*

# The repo goes in as a tarball so the entrypoint can drive the REAL
# installer via KAVKASH_TARBALL_URL=file://... — download, checksum
# verify, extract and the no-systemd manual-start fallback all run with
# zero network. The repo is wrapped in a single top-level dir (GitHub's
# <repo>-<sha>/ layout): install.sh's unpack() locates the source by
# taking the first */ entry, so a flat tarball would make it find
# docker/ instead of the repo root. Staged outside /src so the tarball
# can't include itself.
COPY . /src
RUN mkdir -p /tmp/pkg \
 && tar -C /src -cf - . | tar -C /tmp/pkg -xf - \
 && mv /tmp/pkg /tmp/kavkash-demo \
 && tar -C /tmp -czf /tmp/kavkash.tar.gz kavkash-demo

# Bake the hook wiring into the rc files so EVERY interactive shell
# (docker exec included) lands in a kavkash session automatically.
# Guarded: the functions files only exist after the entrypoint's first
# install run, and a mounted volume may shadow the install dir.
# HISTFILE: the host history is mounted read-only at /root/.bash_history
# (import reads it there at install time); give interactive bash its own
# writable file so exit-time history writes don't hit the read-only mount.
RUN mkdir -p /root/.config/fish \
 && printf '\nHISTFILE=/root/.kavkash-bash-history\n[ -f /root/.local/share/kavkash/functions.bash ] && source /root/.local/share/kavkash/functions.bash\n' >> /root/.bashrc \
 && printf '\n[ -f /root/.local/share/kavkash/functions.zsh ] && source /root/.local/share/kavkash/functions.zsh\n' >> /root/.zshrc \
 && printf '\nif test -f /root/.local/share/kavkash/functions.fish\n    source /root/.local/share/kavkash/functions.fish\nend\n' >> /root/.config/fish/config.fish

ENTRYPOINT ["/src/docker/entrypoint.sh"]
CMD ["bash"]
