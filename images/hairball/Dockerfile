# syntax=docker/dockerfile:1

# hairball: a CLI that collects my public activity (ATProto, GitHub, Last.fm)
# into a SQLite file, and writes the JSON of a calendar heatmap.
#
# Build context: a checkout of https://git.tomplanche.com/tom/hairball.
# A job, not a server: each run of hairball-sync does one sync, then the
# export. Mount the data directory (the database and the lock) on /data, the
# export directory on /export, and the config on /etc/hairball/config.toml.

FROM rust:1-slim-trixie AS build
# lastfm-client uses OpenSSL on Linux.
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# The cache mounts keep the crates and the compiled dependencies between builds.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked \
 && mkdir /out \
 && cp target/release/hairball /out/

FROM debian:trixie-slim
# libssl3t64 and ca-certificates: TLS. tzdata: the export puts the events into
# the days of the time zone of the config.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3t64 tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 1000 --create-home app \
 && mkdir -p /data /export /etc/hairball \
 && chown app:app /data /export
COPY --from=build /out/hairball /usr/local/bin/
COPY --chmod=755 <<'EOF' /usr/local/bin/hairball-sync
#!/bin/bash
# hairball-sync [--full]: a sync of all the sources, then the export of the
# calendar. A lock in /data lets only one sync run at a time: all the runs
# write to the same SQLite file.
# - Without --full (the frequent run): if a sync runs, skip this run. The
#   running sync gets the same new data.
# - With --full: wait for the running sync, then read all the history again.
#   A full run also marks the records deleted upstream.
# A sync stops after 1 hour, so a blocked run cannot keep the lock.
set -uo pipefail
exec 9> /data/hairball.lock
if [ "${1:-}" = "--full" ]; then
    flock 9
    timeout 1h hairball sync --full
else
    if ! flock -n 9; then
        echo "$(date -Is) skip: another sync runs"
        exit 0
    fi
    timeout 1h hairball sync
fi
status=$?
# Also after a failed sync: the other sources have new data.
hairball export || status=1
exit "$status"
EOF
USER app
# The CLI reads config.toml in the working directory. There is no .env here,
# so the CLI cannot find one by accident: the secrets come from the env file.
WORKDIR /etc/hairball
# NO_COLOR: the logs go to a file (cron), with no ANSI colors.
ENV RUST_LOG=info \
    NO_COLOR=1
CMD ["hairball-sync"]
