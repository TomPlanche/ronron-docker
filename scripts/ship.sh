#!/usr/bin/env bash
# Builds and starts apps on ronron, from the root of this repository:
#   scripts/ship.sh <service>...
#
# `just ship` runs it after `git pull`. It updates the sources in src/, tags
# the images that run now as <image>-previous (to go back to them), builds the
# images of the given services, and starts the servers among them.
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: scripts/ship.sh <service>..." >&2
    exit 2
fi

bash scripts/sources.sh init
bash scripts/sources.sh pull

# --no-env-resolution: the list of the images needs no env file.
images=$(docker compose --profile tools config --no-env-resolution --images "$@" | sort -u)
for image in $images; do
    if docker image inspect "$image" > /dev/null 2>&1; then
        docker tag "$image" "$image-previous"
    fi
done

bash scripts/build.sh "$@"

# atkuzu-daily is a job, not a server: cron and `just publish-daily` run it.
servers=()
for service in "$@"; do
    case "$service" in
        atkuzu-daily) ;;
        *) servers+=("$service") ;;
    esac
done
if [ "${#servers[@]}" -gt 0 ]; then
    docker compose up -d --wait "${servers[@]}"
fi
docker compose ps
