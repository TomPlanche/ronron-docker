#!/usr/bin/env bash
# Registers forgejo-runner in Forgejo, on ronron, from the root of this
# repository: `just runner-register`. Forgejo must run.
#
# Offline registration: the token is a secret of 40 hexadecimal characters that
# Forgejo and the runner share. The first 16 characters identify the runner
# (the uuid of forgejo-runner/config.yml), the other 24 are the secret. The
# script makes data/forgejo-runner/token when it is missing, then registers it
# in Forgejo. It can run again: Forgejo updates the runner with the same
# identifier. To change the secret, delete the token file, run the script,
# then restart forgejo-runner.
set -euo pipefail

# The identifier of the runner. It must match the uuid of
# forgejo-runner/config.yml (the same 16 characters, in hexadecimal ASCII).
id=86f7c8a86c3cfe66
dir=data/forgejo-runner
token=$dir/token

# The image of the runner runs as uid 1000, the owner of these folders.
mkdir -p "$dir/cache"
if [ ! -s "$token" ]; then
    # No newline: Forgejo wants exactly 40 characters.
    (umask 077 && printf '%s%s' "$id" "$(openssl rand -hex 12)" > "$token")
    echo "new token in $token"
fi

if [ "$(head -c 16 "$token")" != "$id" ]; then
    echo "error: $token does not start with $id, the identifier of forgejo-runner/config.yml" >&2
    exit 1
fi

# A global runner (no --scope): it runs the jobs of all the repositories.
docker compose exec -T -u git forgejo \
    forgejo forgejo-cli actions register --name ronron --secret-stdin=- < "$token"
