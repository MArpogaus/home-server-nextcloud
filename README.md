# service-nextcloud

Nextcloud in a rootless Podman pod under the `nextcloud` user, deployed by
Ansible. The pod is reached through BunkerWeb (`service-bunker`); the host is
set up by `ansible-base`, whose README is the entry point for the project.

## Architecture

| Container | Image | Role |
|---|---|---|
| nextcloud-db | postgres:18-alpine | Database (`pg_isready` health check) |
| nextcloud-redis | redis:8-alpine | Cache (`redis-cli ping`) |
| nextcloud-app | ghcr.io/marpogaus/nextcloud:34 (custom, fpm) | PHP-FPM |
| nextcloud-web | nginx:mainline-alpine | Serves the app; `status.php` health check covers the whole stack |
| nextcloud-cron | custom image | `cron.php` every 5 min |
| nextcloud-preview | custom image | `preview:pre-generate` every 10 min, own memory ceiling |
| nextcloud-recognize | custom image | Recognize classifier worker; installs the app and its models |
| nextcloud-push | custom image | `notify_push` daemon |

The pod publishes `8080` on loopback only. BunkerWeb runs as a different
rootless user with its own container network and reaches the host through
pasta's host-loopback mapping. Inside the pod everything uses `127.0.0.1`,
because containers in a pod share a network namespace and bind IPv4 only.

### Logging

The pod runs with `LogDriver=passthrough` (`quadlets/container.d/log.conf`),
so container output reaches the journal at the unit's priority instead of
`err`. A journal stream is a socket, and nginx and php-fpm open their logs by
path (`/dev/stdout`, `/proc/self/fd/2`), which fails with `ENXIO`. Both
therefore log via syslog to `/dev/log`, mounted into the two containers:

- nginx: `error_log`/`access_log syslog:server=unix:/dev/log,tag=nginx` in
  `quadlets/configs/nginx.conf.j2`, and `Exec=nginx -e stderr -g "daemon off;"`
  because nginx opens its compiled-in log path before it reads the config.
- php-fpm: `error_log = syslog` from `containers/context/configs/zz-pool.conf`,
  `syslog.ident = php-fpm`. The fpm access log is off; nginx logs every
  request as JSON.
- Nextcloud itself: `log_type syslog`, tag `nextcloud`, one JSON object per
  line, set by the role in `data/config/log.config.php`. The `errorlog` type
  went through php-fpm's caught worker output, which php-fpm drops when its
  own log is syslog; the application log was silently gone for half a day.

Look for them with `journalctl SYSLOG_IDENTIFIER=nginx`, `=php-fpm` and
`=nextcloud`. The `occ` processes (cron, worker) write to their unit's stream
directly.

## Configuration

### Sizing (8 GB host)

| Var | Default |
|---|---|
| `nextcloud_service_php_max_children` | 8 |
| `nextcloud_service_php_memory_limit` | 512M |
| `nextcloud_service_app_extra_args` | `--memory=2G` + tmpfs `/tmp` |
| `nextcloud_service_db_extra_args` | `--memory=768M` |
| `nextcloud_service_cron_extra_args` | `--memory=2G` |
| `nextcloud_service_preview_extra_args` | `--memory=2G --cpus=1` |
| `nextcloud_service_recognize_extra_args` | `--memory=2G --cpus=3` |
| redis / web / push | 128M each |

Capabilities: `container.d/hardening.conf` drops all. Each container adds
back what its root entrypoint needs (`AddCapability=` in the Quadlet, with
the reason). `SETUID SETGID` everywhere: the image switches to `www-data`.

The ceilings add up to more than the host has. They are limits, not
reservations, and the two heavy jobs are bursty. PHP's `max_children` times
`memory_limit` is the real budget; override one without the other and the
deployment breaks.

### Secrets and domains

DB credentials, admin user, trusted domains and PHP tuning come from
`secrets/vars.yml` through `quadlets/configs/nextcloud.env.j2`. The role sets
`overwrite.cli.url`, `overwriteprotocol`, `maintenance_window_start` and the
notify_push endpoint with `occ` on every run (`nextcloud_service_settings`),
reading each value first so an unchanged deploy reports no change.
`occ notify_push:self-test` proves the push path, but it calls the public URL,
which on the test VM resolves to the real host: run it on the host it tests.
There, four of its five checks pass; the fifth compares client addresses on
a request that went out and came back through the router, whose hairpin NAT
adds the home address as a hop that no trusted-proxy list should contain.
Clients from outside carry one hop, the proxy, and are resolved correctly.
`nextcloud_service_trusted_proxies` defaults to RFC1918 plus link-local
because BunkerWeb's traffic arrives through the host.

Database and admin credentials are podman secrets, not environment variables:
absent from `podman inspect` and `/proc/<pid>/environ`. Both images accept the
`*_FILE` convention. The role reads each secret before it writes it and writes
only a value that differs, because `podman secret create --replace` on every
run would restart the pod every run. A written secret does restart the pod.

The image applies `NEXTCLOUD_TRUSTED_DOMAINS` in its first-run install branch
only. The role sets the domains with `occ` on every run, so a domain added
later reaches `config.php`. "Trusted domain error" or HTTP 400 through the
proxy therefore means the variable is wrong:

```bash
podman exec -u www-data nextcloud-app php occ config:system:get trusted_domains
```

### Nextcloud version

The default stays on 34 until Preview Generator supports 35: on a 35 server
its install fails with "not compatible" and the preview container restart-loops
(2026-09-19). CI builds 32 to 35, so the switch is one variable. A major
upgrade keeps two 2 GB images plus snapshots on disk; the test VM has 40 GB
for that reason.

`:34` is published from `main` only; a push to `dev` publishes `:34-dev`,
which the test VM follows through its per-host vars. `AutoUpdate=registry`
pulls whatever the tag points at that night, so a tag the real host follows
must not move on every commit. The daily schedule rebuilds a version only
when its base image changed (label `org.opencontainers.image.base.digest`).

## Backups

`pg-dumpall.timer` (23:55) dumps the cluster into `data/db_dumps/`, so the
nightly Btrfs snapshot (00:00, `ansible-base`) holds a consistent database;
a drop-in orders the snapshot after the dump for the night both start late.
The dump is written as `.tmp` and renamed on success, so a dump that died
halfway is never snapshotted under a real name. Dumps older than 30 days are
pruned. The dump has no `DROP` statements and the
container has no `postgres` role: `nextcloud` is the superuser.

`data/custom_apps` is its own Btrfs subvolume. A snapshot does not recurse into
a nested subvolume, so app code and the Recognize models (gigabytes the app
store hands back) stay out of every snapshot and backup. The subvolume is
created owned by the service user and kept at mode `0755`: nginx runs as its
own uid in `nextcloud-web` and must traverse it, or every app asset answers 404.

### Restoring the own dump

Do this once deliberately before you trust the backups. The functional suite
proves that a dump is produced and structurally complete, not that it restores.

```bash
systemctl --user -M nextcloud@ stop nc-pod.service
systemctl --user -M nextcloud@ start nextcloud-db.service
podman exec nextcloud-db psql -U nextcloud -d postgres -c "DROP DATABASE nextcloud;"
podman exec -i nextcloud-db psql -U nextcloud -d postgres < dump-<timestamp>.sql
podman exec nextcloud-db psql -U nextcloud -d nextcloud -tAc "select count(*) from oc_users"
systemctl --user -M nextcloud@ start nc-pod.service
```

The two `role already exists` errors at the top of the dump are expected.

### Restoring from a copy of another host

The 2026-09-19 migration restored a `pg_dumpall -c` dump plus the data
directory from a NAS onto a fresh deploy. The order that worked, with the
traps met on the way:

1. **Deploy empty first** and let it come up clean. A broken deployment that
   already holds the only copy of the data is a worse place to debug from.
2. **Copy the files as root, then hand them over.** Stop the pod, `chown -R
   root:root` the data directory for the copy, run rsync as a transient unit
   (`systemd-run --unit=nc-restore-files`, so a dropped SSH session cannot
   stop it) with the log redirected inside the unit's shell. Then
   `chown -R nextcloud:nextcloud` the service home and
   `podman unshare chown -R 33:33 data config custom_apps` as the service
   user: `www-data` maps to a subuid, and `podman unshare` does the arithmetic.
   Include `custom_apps`, because the first chown took it too; an app
   directory the container cannot read gets disabled by `occ upgrade`.
   Mount NFS `hard`, never `soft`: a soft mount returns EIO when the NAS is
   slow, rsync skips the file and the unit still ends. A finished unit is not
   a finished copy; run the rsync dry run again and expect no output.
3. **Restore `config.php`** from the copy. It holds `instanceid`,
   `passwordsalt` and `secret`; without them every credential Nextcloud
   encrypted stays unreadable. The database does not carry them.
4. **Restore the dump as the bootstrap superuser.** `pg_dumpall -c` opens
   with `DROP ROLE nextcloud`, which the server refuses for the role that owns
   `postgres` and `template1`, and `REASSIGN OWNED` does not help. Strip the
   dump's three statements about that role and its database, and give the
   role its password back afterwards through stdin (`psql -c` does not
   interpolate `:'pw'`):

   ```bash
   P="podman exec -i nextcloud-db psql -v ON_ERROR_STOP=1 -U nextcloud"
   $P -d postgres -c "DROP DATABASE IF EXISTS nextcloud;"
   sed -E '/^DROP ROLE nextcloud;$/d; /^CREATE ROLE nextcloud;$/d; /^DROP DATABASE nextcloud;$/d' "$DUMP" \
     | $P -d postgres -q
   podman exec nextcloud-db sh -c \
     "echo \"ALTER ROLE nextcloud PASSWORD :'pw';\" | psql -U nextcloud -d postgres -v ON_ERROR_STOP=1 -v pw=\"\$(cat /run/secrets/nextcloud_service_db_password)\""
   ```

   `ON_ERROR_STOP=1` matters: without it psql reports every error and exits 0.
   Count `information_schema.tables` and `oc_users` before you go on.
5. **Reconcile.** `occ upgrade`, `maintenance:repair --include-expensive`,
   `db:add-missing-indices`, `db:add-missing-columns`,
   `db:add-missing-primary-keys`, `files:scan --all`, `files:scan-app-data`,
   `setupchecks`. Then read the *disabled* list of `occ app:list`: a bundled
   app the old host had disabled never ran its migrations, but core still
   writes its columns. Here `systemtags` was off, `oc_systemtag` lacked `etag`
   and `color`, and every Recognize tagging run died with `SQLSTATE[25P02]`.
   `occ app:enable systemtags` added them. Apps that the old host had
   installed from the store are not in the copy; `occ app:install` them.
6. **Previews.** The copy left the preview files out, but Nextcloud 34 tracks
   previews in `oc_previews`, so it believed every preview existed and
   generated none; `files:scan-app-data` does not repair that.
   `occ preview:cleanup` wipes table and tree, then `preview:generate-all` in
   the preview container rebuilds them (hours; it aborts on a race with
   another process saving the same preview and skips finished work on rerun).
7. **Recognize** keeps its results in the database, so `occ recognize:recrawl`
   is enough. For the initial bulk run, `occ recognize:clear-background-jobs`
   plus `occ recognize:classify` in the recognize container runs everything
   in the foreground and avoids the job bookkeeping described below.

## Recognize

Recognize classifies in background jobs, which otherwise run inside
`nextcloud-cron`. The worker container runs `occ background-job:worker` for the
five `Classify*Job` classes of Recognize 12 (`RECOGNIZE_JOB_CLASSES` overrides
the list) with `php -d memory_limit=1G`; a 50-face batch exhausted the 512 MB
php-fpm limit. cron.php cannot exclude a class, so it still takes a classify
job now and then; with `concurrency.enabled=false` (pinned by the worker
entrypoint) that attempt returns in ten seconds whenever the worker holds a
job. When the worker is idle, cron runs the classifier itself, and one node
process reached 1 GB: the cron container has the same 2 GB ceiling as the
worker for that reason. The entrypoint also pins Recognize's low-memory batch sizes (faces 50,
imagenet 20, landmarks 20, movinet 5): a 200-face batch took node to 1.9 GB.

At one CPU the classifier managed an image every 35 s; the container has three
(`--cpus=3`). Sequential by design, imagenet first, faces after.

Nextcloud 34 kills a worker now and then with a duplicate snowflake `run_id` in
`oc_job_runs` (`SQLSTATE[23505]`, several `occ` processes in one pod), and a
job whose process died keeps `reserved_at` set, which blocks the classifiers
for 12 hours. `unstick-jobs.timer` resets reservations older than 30 minutes
every 15 minutes.

The worker installs the app, fetches the models and the node binary (about
2.9 GB, once), and starts late on a fresh host for that reason. The other two
app containers install and enable their apps the same way: preview and push.

## Traps in this role

- The image entrypoint chowns the data and config mount points to `www-data`
  (uid 33 in the container). That fails when the host directory does not
  belong to the subuid that uid 33 maps to; the entrypoint exits 23 and the
  container restarts forever. The role runs `podman unshare chown 33:33` first.
- A directory left in group root is unmapped inside the rootless user
  namespace, and `podman unshare chown` on it fails with EPERM. Ansible creates
  the directories with an explicit group.
- `Requires=nextcloud-app.service` on `nextcloud-web` stops the web container
  when the app is restarted by hand and does not start it again. The role
  restarts the pod, not single containers. `nextcloud-app` reports healthy
  (`Notify=healthy`) once php-fpm listens, and nginx starts after that; before
  the gate every deploy was 40 nginx restarts.
- The image repository name must be lowercase. podman reports the error at
  pull time only, which looks like a restart loop.

## Role contract

Inherited from `site.yml`: `service_name`, `service_user`, `service_home`,
`service_repo`. The role imports `quadlet_service` from `ansible-base`, which
deploys everything under `quadlets/`: `.j2` files are templated, `container.d/`
drop-ins and all other files are copied, and the pod restarts only when one of
them changed. `quadlet_service_pod: nc`, because the pod file is `nc.pod`, and
`nextcloud.env` is mode `0600`; both are set in `vars/main.yml`. A rewritten
podman secret restarts the pod through `quadlet_service_restart`.

## Custom image

`containers/Containerfile` adds ffmpeg and ghostscript, the three app scripts
(`notify_push.sh`, `previewgenerator.sh`, `recognize-worker.sh`), one php-fpm
drop-in (`zz-pool.conf`: syslog, pool sizing and php values from the
environment) and two `config.php` drop-ins (preview sizes, phone region).
Every container runs the image's own entrypoint; the app container's command
is `php-fpm`, which is what makes the entrypoint install or upgrade
Nextcloud, and the others pass their script as the command. Built and signed
by GitHub Actions, verified through the cosign policy on the host.

## Development

Work on `dev`. Conventional commits.

```bash
pre-commit install --install-hooks -t pre-commit -t commit-msg -t pre-push
```

Plain `pre-commit install` wires up the pre-commit stage only, which leaves the
commit-message and branch hooks dormant.

## License

MIT
