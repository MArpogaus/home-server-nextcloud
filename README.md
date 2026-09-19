# service-nextcloud

Nextcloud in a rootless Podman pod under the `nextcloud` user, managed via Ansible.

## Architecture

| Container | Image | Role |
|---|---|---|
| nextcloud-db | postgres:18-alpine | Database (`pg_isready` health check) |
| nextcloud-redis | redis:8-alpine | Cache (`redis-cli ping`) |
| nextcloud-app | ghcr.io/marpogaus/nextcloud:34 (custom, fpm) | PHP-FPM |
| nextcloud-web | nginx:mainline-alpine | Serves the app; `status.php` health check covers the whole stack |
| nextcloud-cron | custom image | `cron.php` every 5 min |
| nextcloud-preview | custom image | `preview:pre-generate` every 10 min, own memory ceiling |
| nextcloud-recognize | custom image | recognize classifier worker; installs the app and its models |
| nextcloud-push | custom image | `notify_push` daemon |

The pod publishes `8080` on loopback only. Bunkerweb runs as a different
rootless user with its own container network. It still reaches the host
through pasta's host-loopback mapping, so this needs no wider bind. Inside
the pod everything uses `127.0.0.1`, because containers in a pod share a
network namespace and bind IPv4 only.

Nextcloud, audit and PHP-FPM logs go to stderr → journald → Alloy → Loki.

## Configuration

### Sizing (8 GB host)

| Var | Default |
|---|---|
| `nextcloud_service_php_max_children` | 8 |
| `nextcloud_service_php_memory_limit` | 512M |
| `nextcloud_service_app_extra_args` | `--memory=2G` + tmpfs `/tmp` |
| `nextcloud_service_db_extra_args` | `--memory=768M` |
| `nextcloud_service_cron_extra_args` | `--memory=1G` |
| `nextcloud_service_preview_extra_args` | `--memory=2G --cpus=1` |
| `nextcloud_service_recognize_extra_args` | `--memory=2G --cpus=1` |
| redis / web / push | 128M each |

### Secrets

DB credentials, admin user, trusted domains and PHP tuning come from
`secrets/vars.yml` via `nextcloud.env.j2`. `nextcloud_service_trusted_proxies` defaults
to RFC1918 + link-local because Bunkerweb's traffic arrives through the host.

## Backups

`pg-dumpall.timer` (23:55) dumps the DB into `data/db_dumps/` so the nightly
Btrfs snapshot (00:00, from `ansible-base`) is consistent. Dumps older than
30 days are pruned.

`data/custom_apps` is its own Btrfs subvolume, and a snapshot does not recurse
into a nested subvolume. App code and the recognize models therefore stay out
of every snapshot and every backup. They are several gigabytes, and the app
store can hand them back. After a bare-metal restore, the four app containers
install their own apps again. An app that was installed from the web interface
must be installed again by hand.

## Memory

The ceilings add up to more than the host has. That is deliberate: they are
limits, not reservations, and the two heavy jobs are bursty. Previews and
recognize both start after an upload, so they can peak together. If recognize
is killed, only classification stops, and the container restarts. cron.php
keeps running every other background job, which is the reason recognize has a
container of its own.

Recognize classifies in background jobs. The worker takes the five
`Classify*Job` classes of Recognize 12; `RECOGNIZE_JOB_CLASSES` overrides the
list if `occ background-job:list` names other ones. cron.php cannot exclude a
class, so it still takes a classify job now and then, and its 1 GB ceiling then
kills the node process. Only that one job is lost; the worker retries it.

The default stays on 34 until Preview Generator supports 35: on a 35 server
its install fails with "not compatible" and the preview container restart-loops
(seen 2026-09-19). CI builds 35 all the same, so the switch is one variable.

Each of the three app containers installs and enables its own app, the same
way: preview, push and recognize. Recognize also fetches its models and its
node binary, so a fresh host needs no manual step. That download is gigabytes,
so it runs once. The container asks for it again only when the files are
missing. That also covers a restore which carried the app without its models.

The first start therefore takes as long as the download does. The worker
starts after it, so classification simply begins late.

## Traps in this role

The image entrypoint copies the application into `/var/www/html`. Then it
chowns the data and config mount points to `www-data`, which is uid 33 in the
container. That chown fails when the host directory does not already belong to
the subuid that uid 33 maps to. The entrypoint then exits 23 and the container
restarts forever. The role runs `podman unshare chown 33:33` on those
directories first, which does the mapping arithmetic.

Ansible creates the directories with an explicit group. A directory left in
group root is unmapped inside the rootless user namespace, and `podman unshare
chown` on it fails with EPERM.

Database and admin credentials are podman secrets, not environment variables.
The values are then absent from `podman inspect` and from `/proc/<pid>/environ`.
Both images accept the `*_FILE` convention. The role reads each secret before
it writes it, and writes only a value that differs. `podman secret create
--replace` on every run reports a change every time and restarts the whole pod.
A write does restart the pod, because `--replace` alone leaves the containers
on the old value.

The image applies `NEXTCLOUD_TRUSTED_DOMAINS` in its first-run install branch
only. A domain added later never reaches `config.php`, and every proxied
request fails with "Trusted domain error". The role sets the domains with `occ`
on every run instead.

The image repository name must be lowercase. OCI requires this. podman reports
the error at pull time only, which looks like a container restart loop.

## Role Contract

Inherited from `site.yml`: `service_name`, `service_user`, `service_home`,
`service_repo`. The role imports `quadlet_service` from `ansible-base`, which
deploys everything under `quadlets/`: `.j2` files are templated, all other
files are copied, and the pod restarts only when one of them changed.
`quadlet_service_pod: nc`, because the pod file is `nc.pod`, and `nextcloud.env` is mode `0600`. Both are set in `vars/main.yml`. A rewritten podman secret restarts the pod through `quadlet_service_restart`.

## Custom image

`containers/Containerfile` adds ffmpeg/ghostscript, `configure.sh` (PHP-FPM
pool sizing from `PHP_MAX_CHILDREN`), `notify_push.sh`, `previewgenerator.sh`
and config drop-ins. Built and signed by GitHub Actions, verified via cosign
policy on the host.

## Development

Work on `dev`. Conventional commits.

```bash
pre-commit install --install-hooks -t pre-commit -t commit-msg -t pre-push
```

Plain `pre-commit install` wires up the pre-commit stage only, which leaves the
commit-message and branch hooks dormant.

## License

MIT
