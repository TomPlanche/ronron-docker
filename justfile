# ronron-docker: the Docker stack of ronron, the home server (Immich,
# Paperless, Forgejo, Beszel agent, VictoriaMetrics and Grafana, and the apps
# of the public sites: vps-back, site, next-site, atkuzu).
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

# Clone the missing sources of the apps into src/ [local]
init: _local-machine
    bash scripts/sources.sh init

# Update the sources of the apps to their upstream branch, force-pushes included [local]
pull: _local-machine
    bash scripts/sources.sh pull

# Build the images of the apps: all of them, or the given services [local]
build *services: _local-machine
    COMPOSE="{{local}}" bash scripts/build.sh {{services}}

# Build the apps and start the stack locally, then wait for the health checks [local]
local-up: build
    {{local}} up -d --wait --remove-orphans immich-server paperless forgejo victoriametrics grafana vps-back site next-site atkuzu

# Check the local stack [local]
local-test: _local-machine
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    # The body of the last answer: in a file, because a font is binary.
    body=$(mktemp)
    trap 'rm -f "$body"' EXIT
    # check <description> <expected HTTP code> <URL> [text in the body, or !text not in it] [curl options...]
    check() {
        local description=$1 code=$2 url=$3 text=${4:-}
        shift 4 2> /dev/null || shift $#
        local status
        status=$(curl -sS -m 10 -o "$body" -w '%{http_code}' "$@" "$url")
        if [ "$status" != "$code" ]; then
            echo "FAIL  $description: HTTP $status, expected $code"
            failed=$((failed + 1))
        elif [ "${text#!}" != "$text" ] && grep -qF -- "${text#!}" "$body"; then
            echo "FAIL  $description: \"${text#!}\" in the answer"
            failed=$((failed + 1))
        elif [ -n "$text" ] && [ "${text#!}" = "$text" ] && ! grep -qF -- "$text" "$body"; then
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
    check "victoriametrics: health" 200 http://127.0.0.1:8428/health "OK"
    check "grafana: health (database)" 200 http://127.0.0.1:3031/api/health '"database"'
    # The login of env/grafana.env.example.
    grafana=(-u admin:local-test-password)
    check "grafana: data source of grafana/provisioning" 200 http://127.0.0.1:3031/api/datasources/uid/victoriametrics '"url":"http://victoriametrics:8428"' "${grafana[@]}"
    check "grafana: dashboard of grafana/dashboards" 200 http://127.0.0.1:3031/api/dashboards/uid/hetzner-overview '"Hetzner: HTTP and security"' "${grafana[@]}"
    # A query through Grafana: the data source reaches VictoriaMetrics, which
    # holds its own metrics (-selfScrapeInterval).
    check "grafana: query to victoriametrics" 200 "http://127.0.0.1:3031/api/datasources/proxy/uid/victoriametrics/api/v1/query?query=vm_app_version" '"status":"success"' "${grafana[@]}"
    # The apps, on their own ports. In production, the Caddy of the VPS adds the
    # routes (tomplanche.com/api/ to vps-back, for example): the local test of
    # hetzner-docker checks them.
    check "vps-back: root" 200 http://127.0.0.1:8100/ "Hello"
    # A file in the mounted static directory, served under /static/.
    mkdir -p data/vps-back/static
    echo "local test of /static/" > data/vps-back/static/local-test.txt
    check "vps-back: file of data/vps-back/static" 200 http://127.0.0.1:8100/static/local-test.txt "local test of /static/"
    check "vps-back: missing static file" 404 http://127.0.0.1:8100/static/missing.txt
    check "site: home page" 200 http://127.0.0.1:3100/ "<html"
    check "site: no maintenance (env/site.env)" 200 http://127.0.0.1:3100/ "!Working on cleaner deployment methods"
    check "site: static file" 200 http://127.0.0.1:3100/_app/version.json '"version"'
    check "site: sitemap with the last commit" 200 http://127.0.0.1:3100/sitemap.xml "<lastmod>"
    # The maintenance page answers 503 on purpose (src/hooks.server.ts of the front).
    check "next-site: maintenance from env/next-site.env" 503 http://127.0.0.1:3101/ "Working on cleaner deployment methods"
    check "atkuzu: home page" 200 http://127.0.0.1:3102/ "<html"
    check "atkuzu: static file" 200 http://127.0.0.1:3102/_app/version.json '"version"'
    check "atkuzu: login page (form action)" 200 http://127.0.0.1:3102/login "<html"
    if [ -f data/atkuzu/atkuzu.db ]; then
        echo "ok    atkuzu: database in data/atkuzu (migrations at start-up)"
    else
        echo "FAIL  atkuzu: no data/atkuzu/atkuzu.db"
        failed=$((failed + 1))
    fi
    if [ -d data/atkuzu/daily ]; then
        today=$(TZ=Europe/Paris date +%F)
        check "atkuzu: daily index (DAILY_DIR)" 200 http://127.0.0.1:3102/daily/index.json "$today"
        check "atkuzu: daily of today (DAILY_DIR)" 200 "http://127.0.0.1:3102/daily/$today.json" '"puzzles"'
        # The page loads the daily during SSR: the server must find the file too.
        check "atkuzu: /daily renders the daily of today on the server" 200 http://127.0.0.1:3102/daily "solutionSha256"
    else
        echo "skip  atkuzu dailies: run just local-daily first"
    fi
    if [ "$failed" -gt 0 ]; then
        echo "$failed check(s) failed"
        exit 1
    fi

# Write the missing dailies of atkuzu into data/atkuzu/daily [local]
local-daily: _local-machine
    mkdir -p data/atkuzu/daily
    {{local}} run --rm atkuzu-daily

# Show the logs of the local stack [local]
local-logs *services: _local-machine
    {{local}} logs -f {{services}}

# Stop the local stack. `just local-down -v` also deletes the local volumes [local]
local-down *args: _local-machine
    {{local}} down --remove-orphans {{args}}

# Update this repository on ronron, pull the images, start the services: all of them, or the given ones [local or ronron]
deploy *services: _need-ronron
    {{on_stack}} 'cd {{stack_dir}} && git pull --ff-only && git submodule update --init && docker compose config --quiet && docker compose pull --quiet --ignore-buildable {{services}} && docker compose up -d --wait {{services}} && docker compose ps'

# Update this repository on ronron, build the images of apps there and start them: `just ship site next-site`. site and vps-back have a standby copy on the VPS: update it after [local or ronron]
ship +services: _need-ronron
    {{on_stack}} 'cd {{stack_dir}} && git pull --ff-only && bash scripts/ship.sh {{services}}'
    @case " {{services}} " in *" site "* | *" vps-back "*) echo "reminder: update the standby copies on the VPS: just standby, in hetzner-docker" ;; esac

# Write the missing dailies of atkuzu into data/atkuzu/daily on ronron [local or ronron]
publish-daily: _need-ronron
    {{on_stack}} 'cd {{stack_dir}} && docker compose run --rm atkuzu-daily'

# Show the services on ronron [local or ronron]
status: _need-ronron
    {{on_stack}} 'cd {{stack_dir}} && docker compose ps'

# Follow the logs of services on ronron [local or ronron]
logs *services: _need-ronron
    {{on_stack_tty}} 'cd {{stack_dir}} && docker compose logs -f --tail 100 {{services}}'

# Open the Grafana of ronron on http://localhost:3030, through an SSH tunnel [local]
grafana-tunnel: _local-machine _need-ronron
    @echo "Grafana: http://localhost:3030 (Ctrl+C closes the tunnel)"
    ssh -N -L 3030:10.10.0.4:3030 {{ronron}}

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
