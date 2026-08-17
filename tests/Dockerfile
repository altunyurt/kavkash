# Test image for kavkash's test suite — toolchain only; the repo is
# mounted read-only at /app by tests/docker.sh, so dev iterations don't
# rebuild. gawk (not mawk) on purpose: the NUL-framing awk paths are
# verified against GNU awk. util-linux provides `script` (fish stepper
# tests need a pty).
FROM debian:13-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash zsh fish socat sqlite3 gawk fzf ca-certificates util-linux \
 && rm -rf /var/lib/apt/lists/*
