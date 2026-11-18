#!/usr/bin/env python3
"""Checks the registries for new versions of the upstream images of the stack.

    scripts/check-updates.py [name...]           shows the new versions
    scripts/check-updates.py --write [name...]   also writes the new versions
                                                 of the same major into
                                                 compose.yaml

With names, it checks only the images whose name contains one of them, for
example `scripts/check-updates.py --write forgejo immich`.

Run it from the root of this repository, on the local machine (`just updates`).
It reads the images from `docker compose config`, then asks each registry for
the tags of the image (the anonymous API of the registry, no account).

- A tag with the same shape as the current tag is a candidate: `v3.3.5-openvino`
  only compares with `vX.Y.Z-openvino`, so `v3.4.0-rc1` or `latest` never count.
- A new major version is only shown: it can need changes, so read its release
  notes and change the tag by hand.
- The images of the apps (tomplanche/*) and the images pinned by digest (the
  Postgres and the Valkey of Immich) are skipped: change them when Immich
  changes them.
"""

import argparse
import http.client
import json
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

COMPOSE = Path("compose.yaml")
USER_AGENT = "ronron-check-updates"
SYSTEM_CA = "/etc/ssl/cert.pem"

# Where to read the release notes, per repository of the image.
NOTES = {
    "codeberg.org/forgejo/forgejo": "https://codeberg.org/forgejo/forgejo/releases",
    "data.forgejo.org/forgejo/runner": "https://code.forgejo.org/forgejo/runner/releases",
    "ghcr.io/immich-app/immich-server": "https://github.com/immich-app/immich/releases",
    "ghcr.io/immich-app/immich-machine-learning": "https://github.com/immich-app/immich/releases",
    "ghcr.io/paperless-ngx/paperless-ngx": "https://github.com/paperless-ngx/paperless-ngx/releases",
    "grafana/grafana": "https://github.com/grafana/grafana/releases",
    "henrygd/beszel-agent-intel": "https://github.com/henrygd/beszel/releases",
    "victoriametrics/victoria-metrics": "https://github.com/VictoriaMetrics/VictoriaMetrics/releases",
    "docker.io/library/redis": "https://github.com/redis/redis/releases",
    "docker": "https://docs.docker.com/engine/release-notes/",
}


def images() -> list[str]:
    """The images of all the services, the jobs of the profile tools included."""
    output = subprocess.run(
        ["docker", "compose", "-f", str(COMPOSE), "--profile", "tools", "config",
         "--no-env-resolution", "--images"],
        check=True, capture_output=True, text=True,
    ).stdout
    return sorted(set(output.split()))


def split(image: str) -> tuple[str, str, str]:
    """Gives (repository as written, registry host, path in the registry)."""
    repository, _, _ = image.partition("@")
    repository, _, _ = repository.rpartition(":")
    first, _, rest = repository.partition("/")
    if rest and ("." in first or ":" in first):
        host, path = first, rest
    else:
        host, path = "docker.io", repository
    if host == "docker.io":
        host = "registry-1.docker.io"
        if "/" not in path:
            path = "library/" + path
    return repository, host, path


def tls() -> ssl.SSLContext:
    """The Python of python.org on macOS has no CA file of its own: then use
    the one of the system."""
    context = ssl.create_default_context()
    default = ssl.get_default_verify_paths().cafile
    if not (default and Path(default).exists()) and Path(SYSTEM_CA).exists():
        context.load_verify_locations(SYSTEM_CA)
    return context


TLS = tls()


def get(url: str, token: str | None = None) -> urllib.request.addinfourl:
    """A GET, with 3 tries: a registry can drop a connection (Codeberg does)."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    for attempt in range(3):
        try:
            return urllib.request.urlopen(request, timeout=30, context=TLS)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, http.client.HTTPException, OSError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def anonymous_token(challenge: str, path: str) -> str:
    """Gets an anonymous pull token from the realm of a 401 answer."""
    fields = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
    # Codeberg gives the scope "*": ask for the standard pull scope instead.
    scope = fields.get("scope", "*")
    if scope == "*":
        scope = f"repository:{path}:pull"
    query = urllib.parse.urlencode({"service": fields.get("service", ""), "scope": scope})
    with get(f"{fields['realm']}?{query}") as answer:
        body = json.load(answer)
    return body.get("token") or body["access_token"]


def tags(host: str, path: str) -> list[str]:
    """All the tags of an image, page after page."""
    url = f"https://{host}/v2/{path}/tags/list?n=1000"
    token = None
    found: list[str] = []
    while url:
        try:
            answer = get(url, token)
        except urllib.error.HTTPError as error:
            if error.code == 401 and token is None:
                token = anonymous_token(error.headers["WWW-Authenticate"], path)
                continue
            raise
        with answer:
            found += json.load(answer).get("tags") or []
            link = answer.headers.get("Link", "")
        match = re.search(r"<([^>]+)>;\s*rel=\"next\"", link)
        url = urllib.parse.urljoin(f"https://{host}", match.group(1)) if match else ""
    return found


def shape(tag: str) -> re.Pattern[str]:
    """The pattern of the tags with the same shape: each number can change."""
    parts = re.split(r"(\d+)", tag)
    pattern = "".join(r"(\d+)" if part.isdigit() else re.escape(part) for part in parts)
    return re.compile(f"^{pattern}$")


def version(pattern: re.Pattern[str], tag: str) -> tuple[int, ...] | None:
    match = pattern.match(tag)
    return tuple(int(number) for number in match.groups()) if match else None


def check(image: str) -> dict:
    repository, host, path = split(image)
    current = image.rpartition(":")[2]
    pattern = shape(current)
    now = version(pattern, current)
    newer = sorted(
        ((v, tag) for tag in tags(host, path) if (v := version(pattern, tag)) and v > now),
        reverse=True,
    )
    same_major = [tag for v, tag in newer if v[0] == now[0]]
    return {
        "image": image,
        "repository": repository,
        "current": current,
        "minor": same_major[0] if same_major else None,
        "major": newer[0][1] if newer and newer[0][0][0] != now[0] else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--write", action="store_true",
                        help="write the new versions of the same major into compose.yaml")
    parser.add_argument("names", nargs="*",
                        help="check only the images whose name contains one of these words "
                             "(forgejo, immich, for example)")
    args = parser.parse_args()

    checked, skipped = [], []
    for image in images():
        tag = image.rpartition(":")[2]
        if args.names and not any(name in image for name in args.names):
            continue
        if "@" in image or image.startswith("tomplanche/") or not re.search(r"\d", tag):
            skipped.append(image)
        else:
            checked.append(image)

    failed = 0
    results = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for image, result in zip(checked, pool.map(lambda i: _safe(check, i), checked)):
            if isinstance(result, Exception):
                print(f"FAIL  {image}: {result}")
                failed += 1
            else:
                results.append(result)

    updates = []
    for r in results:
        if not r["minor"] and not r["major"]:
            print(f"ok    {r['repository']}:{r['current']}")
            continue
        notes = NOTES.get(r["repository"], "")
        if r["minor"]:
            print(f"NEW   {r['repository']}: {r['current']} -> {r['minor']}")
            updates.append(r)
        if r["major"]:
            print(f"MAJOR {r['repository']}: {r['current']} -> {r['major']} (read the notes, change it by hand)")
        if notes:
            print(f"      notes: {notes}")
        if "immich-app/immich-server" in r["repository"] and r["minor"]:
            print("      compare compose.yaml with the docker-compose.yml of the release: "
                  f"https://github.com/immich-app/immich/releases/download/{r['minor']}/docker-compose.yml")
    for image in skipped:
        print(f"skip  {image}")

    if args.write and updates:
        text = COMPOSE.read_text()
        for r in updates:
            old = f"{r['repository']}:{r['current']}"
            new = f"{r['repository']}:{r['minor']}"
            if f"image: {old}" not in text:
                print(f"error: no `image: {old}` in {COMPOSE}", file=sys.stderr)
                return 1
            text = text.replace(f"image: {old}", f"image: {new}")
        COMPOSE.write_text(text)
        print(f"wrote {len(updates)} new version(s) into {COMPOSE}: check the diff, then test and deploy")

    return 1 if failed else 0


def _safe(function, argument):
    try:
        return function(argument)
    except Exception as error:  # noqa: BLE001 - one image must not stop the others
        return error


if __name__ == "__main__":
    sys.exit(main())
