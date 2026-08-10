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
# fzf (picker), the three shells the hooks integrate with, curl (the
# installer one-liner, and a way to re-run it inside), and
# ca-certificates — slim ships none, so curl would fail its TLS handshake
# without it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash zsh fish \
        socat sqlite3 mawk fzf curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install kavkash with the EXACT documented one-liner — the installer is
# piped to dash, resolves the latest GitHub release, downloads, checksums,
# extracts, and installs into /root/.local/share/kavkash. No systemd in a
# container (the installer would detect that anyway; the flag makes it
# deterministic) and no histories exist during the build, so the import
# prompt is answered "no" — the entrypoint imports mounted ones at
# container start instead. Run under bash -o pipefail: dash alone can't
# report a broken pipe, and a dead curl upstream would otherwise look
# like a successful (empty) install.
RUN bash -o pipefail -c 'export KAVKASH_NO_SYSTEMD=1 KAVKASH_IMPORT=0; curl -fsSL https://raw.githubusercontent.com/altunyurt/kavkash/main/install.sh | dash'

COPY docker/entrypoint.sh /usr/local/bin/kavkash-entrypoint
RUN chmod +x /usr/local/bin/kavkash-entrypoint

# Bake the hook wiring into the rc files so EVERY interactive shell
# (docker exec included) lands in a kavkash session automatically.
# Guarded: a mounted volume may shadow the install dir.
# HISTFILE: the host history is mounted read-only at /root/.bash_history
# (the entrypoint's import reads it there); give interactive bash its own
# writable file so exit-time history writes don't hit the read-only mount.
RUN mkdir -p /root/.config/fish \
 && printf '\nHISTFILE=/root/.kavkash-bash-history\n[ -f /root/.local/share/kavkash/functions.bash ] && source /root/.local/share/kavkash/functions.bash\n' >> /root/.bashrc \
 && printf '\n[ -f /root/.local/share/kavkash/functions.zsh ] && source /root/.local/share/kavkash/functions.zsh\n' >> /root/.zshrc \
 && printf '\nif test -f /root/.local/share/kavkash/functions.fish\n    source /root/.local/share/kavkash/functions.fish\nend\n' >> /root/.config/fish/config.fish

ENTRYPOINT ["/usr/local/bin/kavkash-entrypoint"]
CMD ["bash"]
