# ronron-docker: the Docker stack of ronron, the home server (Immich,
# Paperless, Forgejo, Beszel agent).
#
# [local] recipes run on the local machine: test the stack before a deploy.
# [local or ronron] recipes act on the stack of ronron: over SSH from the local
# machine, or directly on ronron, in ~/ronron-docker.
#
# The recipes that reach ronron over SSH read its SSH target from the RONRON
# environment variable (user@host, or an alias of ~/.ssh/config). This public
# repository does not hold the address.

# --norc: in an SSH session, `bash -c` reads /etc/bash.bashrc, which fails with
# -u ("PS1: unbound variable").
set shell := ["bash", "--norc", "-euo", "pipefail", "-c"]

ronron     := env("RONRON", "")
ronron_dir := "ronron-docker"
local      := "docker compose -f compose.yaml -f compose.local.yaml"

# The real env files exist only on ronron: they tell where a recipe runs.
on_ronron := if path_exists(justfile_directory() + "/env/immich.env") == "true" { "true" } else { "false" }

# How a [local or ronron] recipe runs a command in the stack directory of
# ronron: directly on ronron, over SSH elsewhere.
on_stack     := if on_ronron == "true" { "bash -c" } else { "ssh " + ronron }
on_stack_tty := if on_ronron == "true" { "bash -c" } else { "ssh -t " + ronron }
stack_dir    := if on_ronron == "true" { justfile_directory() } else { ronron_dir }

# List the recipes
default:
    @"{{just_executable()}}" --justfile "{{justfile()}}" --list --unsorted

# Start the stack locally, then wait for the health checks [local]
local-up: _local-machine
    {{local}} up -d --wait --remove-orphans immich-server paperless forgejo

# Check the local stack [local]
local-test: _local-machine
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    # The body of the last answer: in a file, because a font is binary.
    body=$(mktemp)
    trap 'rm -f "$body"' EXIT
    # check <description> <expected HTTP code> <URL> [text in the body] [curl options...]
    check() {
        local description=$1 code=$2 url=$3 text=${4:-}
        shift 4 2> /dev/null || shift $#
        local status
        status=$(curl -sS -m 10 -o "$body" -w '%{http_code}' "$@" "$url")
        if [ "$status" != "$code" ]; then
            echo "FAIL  $description: HTTP $status, expected $code"
            failed=$((failed + 1))
        elif [ -n "$text" ] && ! grep -qF -- "$text" "$body"; then
            echo "FAIL  $description: no \"$text\" in the answer"
            failed=$((failed + 1))
        else
            echo "ok    $description"
        fi
    }
    check "immich: the server answers" 200 http://127.0.0.1:2283/api/server/ping '"pong"'
    check "immich: version 3" 200 http://127.0.0.1:2283/api/server/version '"major":3'
    # The server reads this config from its database.
    check "immich: server config (from the database)" 200 http://127.0.0.1:2283/api/server/config '"isInitialized"'
    check "paperless: login page" 200 http://127.0.0.1:8010/ "<html" -L
    check "forgejo: health (database and cache)" 200 http://127.0.0.1:3010/api/healthz '"pass"'
    check "forgejo: theme of forgejo/custom/public" 200 http://127.0.0.1:3010/assets/css/theme-tomplanche.css "@font-face"
    check "forgejo: home page of forgejo/custom/templates" 200 http://127.0.0.1:3010/ "theme-tomplanche"
    if [ -d forgejo/custom/public/assets/fonts ]; then
        check "forgejo: font of forgejo/custom/public/assets/fonts" 200 http://127.0.0.1:3010/assets/fonts/Monocraft.ttf
    else
        echo "skip  forgejo fonts: no forgejo/custom/public/assets/fonts"
    fi
    if [ "$failed" -gt 0 ]; then
        echo "$failed check(s) failed"
        exit 1
    fi

# Show the logs of the local stack [local]
local-logs *services: _local-machine
    {{local}} logs -f {{services}}

# Stop the local stack. `just local-down -v` also deletes the local volumes [local]
local-down *args: _local-machine
    {{local}} down --remove-orphans {{args}}

# Update this repository on ronron, pull the images, start the services: all of them, or the given ones [local or ronron]
deploy *services: _need-ronron
    {{on_stack}} 'cd {{stack_dir}} && git pull --ff-only && git submodule update --init && docker compose config --quiet && docker compose pull --quiet {{services}} && docker compose up -d --wait {{services}} && docker compose ps'

# Show the services on ronron [local or ronron]
status: _need-ronron
    {{on_stack}} 'cd {{stack_dir}} && docker compose ps'

# Follow the logs of services on ronron [local or ronron]
logs *services: _need-ronron
    {{on_stack_tty}} 'cd {{stack_dir}} && docker compose logs -f --tail 100 {{services}}'

# Stop on ronron: the recipe runs on the local machine
[private]
_local-machine:
    #!/usr/bin/env bash
    if [ "{{on_ronron}}" = "true" ]; then
        echo "error: this recipe runs on the local machine, not on ronron (ronron has env/immich.env)." >&2
        exit 1
    fi

# Stop when RONRON is not set on the local machine: this public repository does not hold the address of the server
[private]
_need-ronron:
    #!/usr/bin/env bash
    if [ "{{on_ronron}}" = "false" ] && [ -z "{{ronron}}" ]; then
        echo "error: set RONRON to the SSH target of ronron (user@host, or an alias of ~/.ssh/config)." >&2
        echo "  bash or zsh: export RONRON=ronron" >&2
        echo "  fish:        set -Ux RONRON ronron" >&2
        exit 1
    fi
