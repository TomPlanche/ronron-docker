#!/usr/bin/env bash
# The sources of the apps, in src/:
#   scripts/sources.sh init   clones the missing sources;
#   scripts/sources.sh pull   updates each source to its upstream branch,
#                             force-pushes included.
#
# Run it from the root of this repository: on the local machine for the local
# test (`just init`, `just pull`), on ronron for the builds (`just ship`).
# ronron has no `just`, so the logic is here and not in the justfile.
set -euo pipefail

clone() {  # clone <directory> <repository> <branch>
    if [ -e "src/$1" ]; then
        echo "ok     src/$1"
    else
        git clone --quiet --branch "$3" "$2" "src/$1"
        echo "cloned src/$1: $2 on $3"
    fi
}

init() {
    mkdir -p src
    clone vps-back https://github.com/TomPlanche/vps-back.git main
    clone site https://github.com/TomPlanche/portfolio-v222.git main
    clone atkuzu https://tangled.org/tomplanche.com/atkuzu main
    # next-site: the next branch of the front, as a git worktree of src/site.
    if [ -e src/next-site ]; then
        echo "ok     src/next-site"
    else
        git -C src/site fetch --quiet origin next
        if git -C src/site show-ref --verify --quiet refs/heads/next; then
            git -C src/site worktree add --quiet "$PWD/src/next-site" next
        else
            git -C src/site worktree add --quiet --track -b next "$PWD/src/next-site" origin/next
        fi
        echo "added  src/next-site: worktree of src/site on next"
    fi
}

pull() {
    shopt -s nullglob
    local dirs=(src/*/)
    if [ "${#dirs[@]}" -eq 0 ]; then
        echo "error: no source in src/, run: scripts/sources.sh init" >&2
        exit 1
    fi
    # src/ holds mirrors for the builds, not work: each one follows its upstream
    # branch, even after a force-push. A local change stops it, to never lose work.
    local failed=0 dir
    for dir in "${dirs[@]}"; do
        echo "== $dir"
        if [ -n "$(git -C "$dir" status --porcelain)" ]; then
            echo "error: $dir has local changes: commit them elsewhere, or drop them" >&2
            failed=$((failed + 1))
            continue
        fi
        git -C "$dir" fetch --quiet
        git -C "$dir" reset --hard --quiet '@{u}'
        git -C "$dir" log --oneline -1
    done
    if [ "$failed" -gt 0 ]; then
        exit 1
    fi
}

case "${1:-}" in
    init) init ;;
    pull) pull ;;
    *)
        echo "usage: scripts/sources.sh init|pull" >&2
        exit 2
        ;;
esac
