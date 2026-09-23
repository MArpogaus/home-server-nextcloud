# home-server-nextcloud

This project runs Nextcloud in a rootless Podman pod. An Ansible role deploys
the pod. This project also builds and signs a custom image.

The pod holds the application, PostgreSQL, Redis, nginx and four job
containers. `home-server-bunker` puts it on the internet.
`home-server-core` prepares the host.

## Running a command as the service user

Every `podman` line below runs as the `nextcloud` user:
`run0 --user=nextcloud -- bash -c '<the line>'`. `home-server-deploy/README.md`,
"Operations", explains the form.

## Architecture

| Container | Role |
|---|---|
| nextcloud-db | Database (`pg_isready` health check) |
| nextcloud-redis | Cache (`redis-cli ping`) |
| nextcloud-app | PHP-FPM, custom image |
| nextcloud-web | nginx; its `status.php` health check covers the whole stack |
| nextcloud-cron | `cron.php` every 5 min |
| nextcloud-preview | `preview:pre-generate` every 10 min |
| nextcloud-recognize | Recognize classifier worker; installs the app and its models |
| nextcloud-push | `notify_push` daemon |

The four job containers run the custom app image.

The pod publishes `8080` on loopback only. BunkerWeb runs as a different
rootless user with its own container network. It reaches the host through
pasta's host-loopback mapping. Inside the pod everything uses `127.0.0.1`,
because containers in a pod share a network namespace and bind IPv4 only.

### Logging

This pod obeys the `passthrough` logging rule
(`home-server-template/CONTRIBUTING.md`, "Rules a service follows") with
syslog. Four programs here open their log by path. All of them write to
`/dev/log`, which every container that runs `occ` or a web server mounts:

- nginx: `quadlets/configs/nginx.conf.j2` sets
  `error_log`/`access_log syslog:server=unix:/dev/log,tag=nginx`. The unit uses
  `Exec=nginx -e stderr -g "daemon off;"`, because nginx opens its compiled-in
  log path before it reads the config.
- php-fpm: `containers/context/configs/zz-pool.conf` sets `error_log = syslog`
  and `syslog.ident = php-fpm`. The fpm access log is off. nginx logs every
  request as JSON.
- Nextcloud itself: the role sets `log_type syslog`, tag `nextcloud`, one JSON
  object per line, in `data/config/log.config.php`. If you use the `errorlog`
  type, the log goes through php-fpm's caught worker output. php-fpm discards
  that output when its own log is syslog, and the application log vanishes
  silently.
- crond in the cron and preview containers: `busybox crond -f -l 0 -S` instead
  of the image's `/cron.sh`, which writes to `/dev/stdout`.

Look for them with `journalctl SYSLOG_IDENTIFIER=nginx`, `=php-fpm` and
`=nextcloud`. An `occ` process prints its own progress to the unit's stream,
and logs to syslog like the rest.

## Configuration

### Images

| Var | Default |
|---|---|
| `nextcloud_service_app_image` | `ghcr.io/marpogaus/nextcloud:35` |
| `nextcloud_service_db_image` | `docker.io/library/postgres:18-alpine` |
| `nextcloud_service_redis_image` | `docker.io/library/redis:8-alpine` |
| `nextcloud_service_nginx_image` | `docker.io/library/nginx:1.31-alpine` |

Renovate bumps postgres, redis and nginx. The app image is built in this
repository, and the workflow matrix owns its major version.

### Sizing (8 GB host)

| Var | Default |
|---|---|
| `nextcloud_service_php_max_children` | 8 |
| `nextcloud_service_php_memory_limit` | 512M |

The Quadlets set the container ceilings with `Memory=`. The ceilings are 2G for
app, cron, preview and Recognize, 768M for the database, and 128M for redis,
web and push. Recognize and the preview generator also carry a `CPUQuota=`.

The ceilings add up to more than the host has. They are limits, not
reservations, and the two heavy jobs are bursty. PHP's `max_children` times
`memory_limit` is the real budget. If you override one without the other, the
deployment breaks.

### Apps

The three helper containers install and enable their own app on start:
preview generator, Recognize and notify_push. Anything else the deployment
needs goes in `nextcloud_service_apps`, which the role enables and leaves
alone afterwards. It holds `admin_audit`. That app writes one log line per
action (who did what to which file). The file activity panels of
`monitoring/dashboards/nextcloud.json` read those lines. If you remove the app,
those panels are empty.

### Secrets and domains

The admin user and the trusted domains come from `secrets/vars.yml`
through `quadlets/configs/nextcloud.env.j2`. That template also holds the fixed
php-fpm values that `zz-pool.conf` reads from the environment. The role sets
`overwrite.cli.url`, `overwriteprotocol`, `maintenance_window_start` and the
notify_push endpoint with `occ` on every run (`nextcloud_service_settings`). It
reads each value first, so an unchanged deploy reports no change.
`occ notify_push:self-test` proves the push path. The test calls the public URL,
which on the test VM resolves to the real host. Run the test on the host that it
tests. There, four of its five checks pass. The fifth check compares client
addresses on a request that went out and came back through the router. The
router's hairpin NAT adds the home address as a hop, and no trusted-proxy list
must contain that hop. Clients from outside carry one hop, the proxy, and
Nextcloud resolves them correctly.

`nextcloud_service_trusted_proxies` defaults to RFC1918 plus link-local,
because BunkerWeb's traffic arrives through the host. Nextcloud skips every
trusted address in `X-Forwarded-For`, and a client can write that header
itself. Nextcloud therefore reads the client address from `X-Real-IP` alone
(`FORWARDED_FOR_HEADERS`), which BunkerWeb sets to the address it sees.

Database and admin credentials are podman secrets, not environment variables.
They do not appear in `podman inspect` or `/proc/<pid>/environ`. Both images
accept the `*_FILE` convention. The role writes a secret only when its value
differs, because a written secret restarts the pod.

The image applies `NEXTCLOUD_TRUSTED_DOMAINS` in its first-run install branch
only. The role sets the domains with `occ` on every run, so a domain added or
renamed later reaches `config.php`. A removed domain does not. Its index keeps
the old value until you clear it with `occ config:system:delete`. "Trusted
domain error" or HTTP 400 through the proxy therefore means that the variable is
wrong:

```bash
podman exec -u www-data nextcloud-app php occ config:system:get trusted_domains
```

## Backups

`pg-dumpall.service` dumps the cluster into `data/db_dumps/`, so the nightly
Btrfs snapshot (00:00, `home-server-core`) holds a consistent database. The dump
has no timer of its own. A drop-in gives the snapshot unit `Wants=` and
`After=` on the dump. That starts the dump in the same transaction and orders it
first. Two timers are two transactions, and `After=` orders nothing between two
transactions.
The service writes the dump as `.tmp` and renames it on success. A dump that
died halfway therefore never reaches a snapshot under a real name. A dump older
than `nextcloud_service_db_dump_retention_days` is pruned, 30 days by default.
The dump has no `DROP` statements, and the container has no `postgres` role.
`nextcloud` is the superuser.

On success the unit writes `dump_last_success_timestamp_seconds` to
`/var/lib/node-textfile/dump-<service>.prom`. The role seeds that file with the
deploy time, so a dump that never succeeds raises core's `JobStale` 30 hours
after the deploy.

`data/custom_apps` is its own Btrfs subvolume. A snapshot does not recurse into
a nested subvolume. App code and the Recognize models (gigabytes the app store
hands back) therefore stay out of every snapshot and backup. The subvolume
carries mode `0755`, and `podman unshare chown 33:33` gives it to the
container's `www-data` uid. On the host that is a subuid of the service user,
and not the service user itself. nginx runs as its own uid in `nextcloud-web`
and must traverse the subvolume. If it cannot traverse the subvolume, every app
asset answers 404.

`custom_apps` is therefore the one directory on the host that holds mutable
third-party executables outside every snapshot and backup. A cold start
downloads the apps and the Recognize models again. After a suspected compromise,
empty the directory and let the containers download them again. Do not restore
around it.

### Logging and app paths

An app lands in `custom_apps` only because `apps.config.php` puts it on
`apps_paths`. The image copies that file into the mounted config directory
**only while that directory is still empty**, on the very first container
start. Anything that the role writes into `config/` before then costs the whole
bootstrap. `apps_paths` stays unset, and every app installs into `apps/`. The
image's `rsync --delete` then wipes `apps/` on the next version upgrade. For
that reason the role writes the log drop-in after the install, not before. The
container scripts ask `occ app:getpath` rather than assuming a directory.

### Access log redaction

Several paths carry a live credential in the URI. `/s/<token>` opens a public
share, `/lostpassword/reset/form/<token>/<uid>` resets a password, and the
share page fetches thumbnails and files under its own token. The access log
reaches Loki, which keeps 30 days, so a raw line hands every reader of Grafana
a working link. The `$log_request_uri` map in `nginx.conf.j2` replaces the
token of each such path before the line is written.

Two more fields can carry a token. A page served from a share sends that URL
as the Referer of every request it makes. Public WebDAV sends the share token
as the basic-auth username, which nginx puts in `$remote_user`. Neither field
is logged at all.

## Recognize

Recognize classifies in background jobs, which otherwise run inside
`nextcloud-cron`. The worker container runs `occ background-job:worker` for the
five `Classify*Job` classes of Recognize. It uses `php -d memory_limit=1G`,
because a face batch does not fit in the 512 MB php-fpm limit. cron.php cannot
exclude a class, so it still takes a classify job now and then. The worker
entrypoint pins `concurrency.enabled=false`. That attempt therefore returns in
ten seconds whenever the worker holds a job. When the worker is idle, cron runs
the classifier itself. A single node process takes about 1 GB. The cron
container therefore carries the same 2 GB ceiling as the worker. The entrypoint
also pins Recognize's low-memory batch sizes (faces 50, imagenet 20, landmarks
20, movinet 5).

The worker has three of the four cores (`CPUQuota=300%`), the preview generator
one. The work is sequential by design, imagenet first, faces after.

Nextcloud reserves a background job by writing `reserved_at` on its `oc_jobs`
row. A job whose process dies keeps that reservation, and the scheduler then
skips the job for 12 hours. Nothing clears stale reservations
automatically. A timer that clears them can free a job that a worker still
processes, and cron then runs that job in parallel. If classification stalls,
look for an `oc_jobs` row whose `reserved_at` is set and whose worker is
gone, and clear that column.

The worker installs the app and fetches the models and the node binary (about
2.9 GB, once). For that reason it starts late on a fresh host. The other two
app containers install and enable their apps the same way: preview and push.

## Traps in this role

- The four script containers (cron, preview, recognize, push) run a shell as
  PID 1, which ignores the image's `SIGQUIT`. `RunInit=true` puts catatonit in
  front, so a pod stop arrives as `SIGTERM`. `SuccessExitStatus=143` says that
  an exit from that signal is not a failure.
- The image entrypoint chowns the data and config mount points to `www-data`
  (uid 33 in the container). That chown fails when the host directory does not
  belong to the subuid that uid 33 maps to. The entrypoint then exits 23, and
  the container restarts forever. The role runs `podman unshare chown 33:33`
  first.
- A directory in group root has no mapping inside the rootless user
  namespace, and `podman unshare chown` on it fails with EPERM. Ansible creates
  the directories with an explicit group.
- `Requires=nextcloud-app.service` on `nextcloud-web` stops the web container
  when you restart the app by hand, and it does not start the web container
  again. The role restarts the pod, not single containers. `nextcloud-app`
  reports healthy (`Notify=healthy`) once php-fpm listens, and nginx starts
  after that. The job containers carry the same `Requires=`.
- The image repository name must be lowercase. podman reports the error at
  pull time only, which looks like a restart loop.

## Monitoring

`monitoring/` holds the log rules and the dashboard that
`home-server-monitoring` collects. Core's `JobStale` covers the dump metric. The
label contract is in its README.

The dashboard is JSON maintained by hand: edit it in Grafana, export it, delete
its `links`, and commit it.

| Alert | Severity | Fires when |
|---|---|---|
| `NextcloudDatabasePanic` | critical | PostgreSQL logged `PANIC` |
| `NextcloudFatal` | critical | Nextcloud logged level 4 |
| `NextcloudCronStale` | warning | crond started no `cron.php` in 30 min |
| `NextcloudErrors` | warning | More than 20 lines of level 3 or higher in 1 h |
| `Nextcloud5xx` | warning | More than 5 % of more than 50 requests answer 5xx in 10 min |
| `NextcloudBruteForce` | warning | More than 10 failed logins from one address in 15 min |

## Operations

### Major upgrade

CI builds the listed majors and tags the highest as `latest`. The role pins a
major and never follows `latest`. The major list is kept by hand in two
places:

- `versions` in `.github/workflows/build.yml`, which passes each major to
  `containers/Containerfile` as `NEXTCLOUD_TAG`
- `nextcloud_service_app_image` in the role defaults. A host follows this one
  unless its own vars override it.

Add the next major to `versions` and let CI publish it before any host points
at it. Check with `skopeo inspect docker://ghcr.io/marpogaus/nextcloud:<major>`.
A tag that CI never published looks like a slow upgrade for the whole
30-minute install wait.

The upgrade is one way, so take a named rollback point first.
`btrfs-snapshot@nextcloud.service` names its snapshot by date and skips a day
that already has one.

```bash
run0 systemctl start pg-dumpall.service
run0 btrfs subvolume snapshot -r /var/services/nextcloud /var/services/snapshots/nextcloud/pre-<major>
```

Change the tag and deploy. The entrypoint runs `occ upgrade`, and the app is
unreachable while it runs. `occ app:list` names the apps that the new major
disabled.

To go back, revert the tag and restore the named snapshot. `config.php` records
the new version, so the old image refuses to start without it. Use
`home-server-deploy/README.md`, "Rolling back", "A service", with
`/var/services/snapshots/nextcloud/pre-<major>` as the source. Delete the named
snapshot when the upgrade is good, because retention covers dated names only:
`run0 btrfs subvolume delete /var/services/snapshots/nextcloud/pre-<major>`.

The role and the image release separately. An entrypoint script runs under
`set -u`, so remove a key from `nextcloud.env.j2` only after CI publishes the
image that no longer reads it.

### Restoring this host's dump

Do this once, before you trust the backups. The functional test proves that the
dump is complete, not that it restores.

The pod stays up. Every client container stops, because a connected client
makes `DROP DATABASE` fail. Every role in the dump already exists, so the
`CREATE ROLE` lines go. With `ON_ERROR_STOP=1` a failed statement fails the
restore; without it psql exits 0 after every error.

```bash
CLIENTS="nextcloud-app nextcloud-cron nextcloud-push nextcloud-preview nextcloud-recognize nextcloud-web"
run0 --user=nextcloud -- systemctl --user stop $CLIENTS
run0 --user=nextcloud -- bash -c '
  set -euo pipefail
  DUMP=/var/services/nextcloud/data/db_dumps/dump-<timestamp>.sql
  podman exec nextcloud-db psql -v ON_ERROR_STOP=1 -U nextcloud -d postgres -c "DROP DATABASE nextcloud;"
  sed -E "/^CREATE ROLE /d" "$DUMP" | podman exec -i nextcloud-db psql -v ON_ERROR_STOP=1 -U nextcloud -d postgres -q'
run0 --user=nextcloud -- systemctl --user start $CLIENTS
run0 --user=nextcloud -- bash -c 'podman exec -u www-data nextcloud-app php occ files:scan --all'
```

The dump rewinds the database to midnight while `data/data` stays current, so
`files:scan --all` is required. A whole-subvolume restore has no such gap.

### Restoring from another host

This restores a `pg_dumpall -c` dump and a data directory from another host
onto a fresh deploy.

1. Deploy an empty host and get the functional test to 0 failed.
2. Stop the pod:
   `run0 --user=nextcloud -- systemctl --user stop nc-pod.service`. Copy the
   files as root in a named unit, so a dropped SSH session cannot stop it
   (`run0 --unit=nc-restore-files -- sh -c 'rsync ... >/var/tmp/rsync.log 2>&1'`).
   Run the rsync dry run again afterwards and expect no output. Then give the
   data directory, never the service home (that is the user's Podman store), to
   the user and to `www-data` inside the containers:

   ```bash
   run0 chown -R nextcloud:nextcloud /var/services/nextcloud/data
   run0 --user=nextcloud -- bash -c 'podman unshare chown -R 33:33 /var/services/nextcloud/data/data /var/services/nextcloud/data/config /var/services/nextcloud/data/custom_apps'
   run0 --user=nextcloud -- systemctl --user start nc-pod.service
   ```

   `db_data` belongs to postgres, so the second chown does not cover `data/`.
   An NFS source must be mounted `hard`: a soft mount turns a slow NAS into
   skipped files.
3. Copy only `instanceid`, `passwordsalt` and `secret` from the source
   `config.php`. Nextcloud's encrypted credentials need them, and the rest of
   the file carries the source host's database, Redis and domain settings.
4. Stop the clients as in "Restoring this host's dump". Then restore as the
   bootstrap role. The server refuses `DROP ROLE` on the role that owns
   `postgres`, and the deploy already created every role in the dump, so the
   `DROP ROLE` and `CREATE ROLE` lines go. The dump's `ALTER ROLE` sets the
   source password, so the last command sets the local one. That command reads
   the Podman secret inside the container and pipes the statement, so the
   password is on no command line:

   ```bash
   run0 --user=nextcloud -- bash -c '
     set -euo pipefail
     DUMP=/var/services/nextcloud/data/db_dumps/<the copied dump>.sql
     podman exec nextcloud-db psql -v ON_ERROR_STOP=1 -U nextcloud -d postgres -c "DROP DATABASE IF EXISTS nextcloud;"
     sed -E "/^DROP ROLE /d; /^CREATE ROLE /d; /^DROP DATABASE nextcloud;\$/d" "$DUMP" |
       podman exec -i nextcloud-db psql -v ON_ERROR_STOP=1 -U nextcloud -d postgres -q
     podman exec nextcloud-db sh -c "{ printf \"\\\\set pw %s\\n\" \"\$(cat /run/secrets/nextcloud_service_db_password)\"; echo \"ALTER ROLE nextcloud PASSWORD :'"'"'pw'"'"';\"; } | psql -v ON_ERROR_STOP=1 -U nextcloud -d postgres"'
   ```

   Check it on the VM first: the quoting of the last line is the fragile
   part. Count `oc_users` before you go on.
5. Start the pod. In `nextcloud-app` run, in this order: `occ upgrade`,
   `maintenance:repair --include-expensive`, `db:add-missing-indices`,
   `db:add-missing-columns`, `db:add-missing-primary-keys`, `files:scan --all`,
   `files:scan-app-data` and `setupchecks`.
   - Read the disabled list of `occ app:list`. A bundled app that is disabled
     on the source never ran its migrations, and its missing columns show up
     later as `SQLSTATE[25P02]` in an unrelated job. Enable it.
   - A file copy does not carry store apps. Install them with
     `occ app:install`.
6. A copy that carries `oc_previews` without the preview files records
   previews that do not exist. Run `occ preview:cleanup`, then
   `preview:generate-all` in the preview container. A rerun skips finished
   work.
7. Recognize keeps its results in the database, so run `occ recognize:recrawl`.
   For a first bulk run, use `occ recognize:clear-background-jobs` and then
   `occ recognize:classify` in the recognize container.

## Role contract

The contract is in `home-server-template/README.md`. Two points are specific
here. `vars/main.yml` sets `quadlet_service_pod: nc`, because the pod file is
`nc.pod`. A rewritten podman secret restarts the pod through
`quadlet_service_restart`.

## Custom image

`containers/Containerfile` adds ffmpeg and ghostscript and the three app scripts
(`notify_push.sh`, `previewgenerator.sh`, `recognize-worker.sh`). It adds one
php-fpm drop-in (`zz-pool.conf`: syslog, and pool sizing and php values from
the environment) and two `config.php` drop-ins (preview sizes, phone region).
Every container runs the image's own entrypoint. The app container's command
is `php-fpm`, which makes the entrypoint install or upgrade
Nextcloud. The other containers pass their script as the command. GitHub Actions
builds and signs the image. The cosign policy on the host checks it.

`.github/workflows/build.yml` publishes every major a host runs: the role
default, and the major a host still pins until its upgrade. `main` publishes
`:<major>`, and the highest major also gets `:latest`. `dev` publishes
`:<major>-dev`, which the test VM follows. A nightly run compares the base image
digest that the last build recorded as a label with the digest
`nextcloud:<major>-fpm` carries now. It rebuilds only the majors whose base
moved. A new major is a hand edit of `versions` in that workflow.

## License

MIT
