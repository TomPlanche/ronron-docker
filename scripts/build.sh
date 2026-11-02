#!/usr/bin/env bash
# Builds the images of the apps from src/: all of them, or the given services.
#   scripts/build.sh [service...]
#
# COMPOSE is the Compose command: `docker compose` (default, on ronron), or
# `docker compose -f compose.yaml -f compose.local.yaml` for the local test
# (`just build`). The images have the architecture of the machine that runs
# the build.
set -euo pipefail

compose=${COMPOSE:-docker compose}

# The front shows its last commit: give it to the build (see images/portfolio).
commit() {  # commit <variable prefix> <source directory>
    local sha
    sha=$(git -C "$2" rev-parse HEAD)
    export "$1_COMMIT_SHA=$sha"
    export "$1_COMMIT_DATE=$(TZ=UTC git -C "$2" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd)"
    export "$1_COMMIT_URL=https://github.com/TomPlanche/portfolio-v222/commit/$sha"
}
commit SITE src/site
commit NEXT src/next-site

# --profile tools: atkuzu-daily is in that profile. Without a service, Compose
# builds each service with a build section: the apps only.
# shellcheck disable=SC2086
$compose --profile tools build "$@"
