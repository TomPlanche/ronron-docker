# ronron-docker

A Docker Compose stack for a home server: a photo library (Immich), a document archive (Paperless-ngx), a git server (Forgejo) and the agent of a resource dashboard (Beszel). All the images come from their upstream registries, with a fixed version: the server builds nothing. A local test checks the stack before each deploy.

## Layout

| Path | Content |
|------|---------|
| `compose.yaml` | The production stack, on the server. |
| `compose.local.yaml` | The changes for a local test: test env files, ports on `127.0.0.1`, no GPU. |
| `env/*.env.example` | The keys of each env file, with the values of the local test. The real `env/*.env` files exist only on the server. |
| `forgejo/` | A git submodule: the repository [tom/forgejo](https://git.tomplanche.com/tom/forgejo), with the theme and the templates of Forgejo (`custom/`, mounted over its data through the `custom/` mechanism of Forgejo, no image build). |
| `host/systemd/docker.service.d/after-wg.conf` | A drop-in of systemd: Docker starts after WireGuard, so the containers can bind the WireGuard address. |
| `host/ronron-backup`, `host/systemd/ronron-backup.{service,timer}` | The nightly backup of the stack with restic (see "Backups"). |
| `justfile` | All the commands. Run `just` to list them. |
| `data/` (not in git) | The data of the services: photos, databases, documents, repositories, and the fonts of the Forgejo theme. |

## Services

| Service | Image | Port on the host | Env file | Mounted |
|---------|-------|------------------|----------|---------|
| `immich-server` | `ghcr.io/immich-app/immich-server:v3.3.5` | `0.0.0.0:2283` | `env/immich.env` | `data/immich/library` on `/data`, `/dev/dri` |
| `immich-machine-learning` | `ghcr.io/immich-app/immich-machine-learning:v3.3.5-openvino` | none | none | the volume `immich-model-cache`, `/dev/dri` |
| `immich-redis` | `valkey/valkey:9`, by digest | none | none | none |
| `immich-postgres` | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, by digest | none | `env/immich.env` | `data/immich/postgres` |
| `paperless` | `ghcr.io/paperless-ngx/paperless-ngx:3.0.5` | `10.10.0.4:8000` | `env/paperless.env` | `data/paperless/{data,media,export,consume}` |
| `paperless-redis` | `redis:8.10.2` | none | none | the volume `paperless-redis` |
| `forgejo` | `codeberg.org/forgejo/forgejo:16.0.4` | `0.0.0.0:3000` (web), `0.0.0.0:2222` (SSH) | none | `data/forgejo` on `/data`, `forgejo/custom/` |
| `beszel-agent` | `henrygd/beszel-agent-intel:0.21.1` | host network: `10.10.0.4:45876` | none | `data/beszel-agent`, the Docker socket (read only), `/dev/dri/card0` |

- `10.10.0.4` is the address of the server on WireGuard (`wg0`). The VPS is `10.10.0.1`. The Caddy of the VPS sends the public names of Immich and Forgejo to `10.10.0.4`, and the VPS sends its port 2223 to port 2222 (the SSH of Forgejo). That config is not in this repository.
- Paperless listens on WireGuard only: the LAN and the internet cannot reach it.
- The ports on `0.0.0.0` are IPv4 only. Docker goes around ufw, and a port without an address also listens on IPv6.
- Each app (Immich, Paperless, Forgejo) has its own network: the containers of an app cannot reach the containers of the other apps.
- Immich transcodes the videos with Quick Sync, and runs its machine learning with OpenVINO, both on the Intel iGPU (`/dev/dri`).
- Immich and its Postgres read their password from `env/immich.env`. Postgres uses it only to create a new database. The user (`postgres`) and the database (`immich`) are in `compose.yaml`.
- The database of Paperless and of Forgejo is SQLite, in their data folder.
- The fonts of the Forgejo theme have a license that does not allow them in a public repository. The repository forgejo ignores them: copy them into `forgejo/custom/public/assets/fonts`. Without them, the theme uses fallback fonts.
- The Beszel agent listens on WireGuard only. The Beszel hub (on the VPS) connects to it with SSH. The agent accepts only the public key of the hub (`KEY` in `compose.yaml`, not a secret). See "Monitoring".
- Each container keeps 3 log files of 10 MB at most.

## Local test

Requirements: Docker with Compose 2.24 or later, `just`, `curl`, and this repository with its submodule: clone it with `git clone --recurse-submodules`, or run `git submodule update --init` in a clone.

1. Start the stack. The first start downloads the images (some GB). The command waits for the health checks:

   ```bash
   just local-up
   ```

   The local test does not start `immich-machine-learning` (a large image) or `beszel-agent` (it needs the hub).

2. Run the checks:

   ```bash
   just local-test
   ```

3. Open http://localhost:2283 (Immich: make the first user), http://localhost:8010 (Paperless, user `admin`, password `local-test-password`) and http://localhost:3010 (Forgejo). Paperless and Forgejo are not on ports 8000 and 3000, so that the local test of another stack can use these ports at the same time.

4. Stop the stack. `-v` also deletes the local database of Immich:

   ```bash
   just local-down -v
   ```

To see the Forgejo theme with its fonts, copy them into `forgejo/custom/public/assets/fonts` first.

## Deploy

### On the server

The server needs:

- Docker with the Compose plugin, usable by the SSH user (member of the `docker` group);
- WireGuard on `wg0`, with the address `10.10.0.4`, and Docker that starts after it. Install the drop-in once:

  ```bash
  sudo install -D -m 644 host/systemd/docker.service.d/after-wg.conf /etc/systemd/system/docker.service.d/after-wg.conf && sudo systemctl daemon-reload
  ```

- the Intel iGPU in `/dev/dri`;
- for the GPU stats of Beszel: `kernel.perf_event_paranoid=2`. Debian sets 3, which blocks `intel_gpu_top` even with `CAP_PERFMON`:

  ```bash
  echo "kernel.perf_event_paranoid=2" | sudo tee /etc/sysctl.d/99-intel-gpu-beszel.conf && sudo sysctl -p /etc/sysctl.d/99-intel-gpu-beszel.conf
  ```

- this repository in `~/ronron-docker`, with its submodule (`git clone --recurse-submodules`);
- the env files `env/immich.env` and `env/paperless.env`, made from `env/*.env.example` with the real values;
- the data of the services in `data/` (see "New server").

### The address of the server

This repository does not hold the address of the server. The recipes that reach it read its SSH target from the `RONRON` environment variable (`user@host`, or an alias of `~/.ssh/config`), and they stop when it is not set. Set it once on the local machine, for example in fish:

```bash
set -Ux RONRON ronron
```

In bash or zsh, put `export RONRON=ronron` in the shell profile.

On the server itself, `RONRON` is not necessary. The recipes find out where they run from the env files: the real `env/*.env` files exist only on the server. There, `just deploy`, `just status` and `just logs` run their command directly, without SSH. The `local-*` recipes refuse to run there.

### Each deploy

1. Change the stack on the local machine. Then check it: `just local-up` and `just local-test`.
2. Commit and push.
3. `just deploy <service>...`, for example `just deploy forgejo`. The recipe updates this repository on the server (`git pull --ff-only`, then `git submodule update --init`), checks the config, pulls the images and starts the services. Without a service, it starts all the services.

### Update an image

1. Read the release notes of the app. Immich, mostly, can need changes in `compose.yaml`: compare with the `docker-compose.yml` of its release.
2. Change the tag in `compose.yaml`, then do "Each deploy".

The images of Postgres and Valkey for Immich have a digest, as in the compose file of Immich: change them only when Immich changes them.

To go back, put the old tag again, then deploy. Before an update of Immich or Postgres, make a backup (see "Backups"): a new version can change the database, and the old version cannot read it after.

### Update the theme of Forgejo

The submodule `forgejo` points to one commit of [tom/forgejo](https://git.tomplanche.com/tom/forgejo). `just deploy` puts the submodule on that commit, not on the last commit of `tom/forgejo`. So a change of the theme needs 2 commits:

1. Commit and push the change in `tom/forgejo`.
2. Here, move the submodule to the last commit, and check it locally:

   ```bash
   git submodule update --remote forgejo && just local-up && just local-test
   ```

3. Commit the new commit of the submodule (`git add forgejo`), push, then deploy: `just deploy forgejo`. Forgejo reads the templates at start-up, so the deploy restarts it.

### New server

`just deploy` starts the services with the data that is in `data/`. When a folder is empty, the app starts with no data: Immich and Forgejo make a new database. So put the data in place before the first deploy:

| Folder | Content |
|--------|---------|
| `data/immich/library` | The photos and videos of Immich, its thumbnails and its database dumps. |
| `data/immich/postgres` | The database of Immich. |
| `data/paperless/{data,media,export,consume}` | The database, the documents, the exports and the inbox of Paperless. |
| `data/forgejo` | The repositories, the SQLite database and the config (`gitea/conf/app.ini`) of Forgejo. |
| `data/beszel-agent` | The identity of the agent for the hub. |
| `forgejo/custom/public/assets/fonts` | The fonts of the Forgejo theme (not in git, see "Services"). |

### Monitoring

The Beszel hub runs on the VPS. To add this server to the hub:

1. In the hub, add a system: the name `ronron`, the host `10.10.0.4`, the port `45876`.
2. If the public key of the hub is not the `KEY` of `compose.yaml`, copy the key of the "Add system" dialog into `KEY`, then deploy `beszel-agent`.

The agent sends the CPU, RAM, disks (the system disk and the backup disk), network, temperatures, GPU and containers of the server.

### Backups

`data/` and `env/` hold all the state of the stack. `host/ronron-backup` saves them every night at 03:30 into a restic repository on the backup disk (`/srv/backup/restic`), with one tag per part:

| Tag | Content | Stop |
|-----|---------|------|
| `env` | `env/` | none |
| `forgejo` | `data/forgejo`, the fonts of the theme | `forgejo`, during the snapshot |
| `paperless` | `data/paperless` | `paperless`, during the snapshot |
| `immich` | `data/immich/library`, without the thumbnails and the transcoded videos (Immich makes them again) | none |

- The script stops nothing else, and it starts the stopped services again, also after an error.
- The files of a running Postgres are not a consistent copy, so the script does not save `data/immich/postgres`. To restore Immich, use the database dumps that Immich writes every night at 03:00 in `data/immich/library/backups`.
- It keeps 7 daily, 4 weekly and 6 monthly snapshots, then reads again 1 % of the data to check the repository.
- At the end, if all went well, it sends a heartbeat to a push monitor of Uptime Kuma. A missing heartbeat makes Kuma send an alert.
- It stops when the backup disk is not mounted.

Install it on the server, once:

1. Put the password of the restic repository in `/root/.restic-password`, and the push URL of the Kuma monitor, without `?status=...`, in `/root/.kuma-push-url`. Both files: owner root, mode 600. Without the URL file, the script sends no heartbeat.
2. Install the script and its units, then start the timer:

   ```bash
   sudo install -m 755 host/ronron-backup /usr/local/sbin/ronron-backup && sudo install -m 644 host/systemd/ronron-backup.service host/systemd/ronron-backup.timer /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now ronron-backup.timer
   ```

3. Run one backup now, and check its end:

   ```bash
   sudo systemctl start ronron-backup.service && journalctl -u ronron-backup.service -n 20 --no-pager
   ```

## Recipes

| Recipe | Runs on | What it does |
|--------|---------|--------------|
| `just local-up` | local | Starts the local stack, then waits for the health checks. |
| `just local-test` | local | Checks the local stack. |
| `just local-logs [service...]` | local | Follows the logs of the local stack. |
| `just local-down [-v]` | local | Stops the local stack. `-v` also deletes its volumes. |
| `just deploy [service...]` | local or server | Updates this repository on the server, pulls the images and starts the services. |
| `just status` | local or server | `docker compose ps` on the server. |
| `just logs [service...]` | local or server | Follows the logs on the server. |

## Things to know

- A restart of Immich or Forgejo stops it for some seconds. The Caddy of the VPS answers 502 during that time.
- Docker keeps old images. Clean them on the server from time to time with `docker image prune`.
- Compose reads `KEY=value` lines in the env files. A value with a `$` must be in single quotes, or Compose replaces the variable.
- `env/*.env` and `data/` hold secrets and files that git does not track. Back them up with the server.
