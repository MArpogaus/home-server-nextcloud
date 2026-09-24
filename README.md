# home-server-nextcloud

This project deploys Nextcloud as the rootless Podman pod `nc` and builds its
signed app image. `home-server-bunker` puts the pod on the internet.

| Container | Job | Memory ceiling |
|---|---|---|
| nextcloud-db | PostgreSQL | 768M |
| nextcloud-redis | Cache | 128M |
| nextcloud-app | PHP-FPM, custom image | 2G |
| nextcloud-web | nginx; `status.php` health check | 128M |
| nextcloud-cron | `cron.php` every 5 min | 2G |
| nextcloud-preview | `preview:pre-generate` every 10 min, 1 CPU | 2G |
| nextcloud-recognize | Recognize classifier worker, 3 CPUs | 2G |
| nextcloud-push | `notify_push` | 128M |

## Configuration

`ansible-role/nextcloud_service/defaults/main.yml` has the full list.

| Variable | Default | Meaning |
|---|---|---|
| `nextcloud_service_db_password`, `_admin_password` | empty | Required |
| `nextcloud_service_admin_user` | `admin` | Admin of the first install |
| `nextcloud_service_trusted_domains` | `cloud.example.com` | Space-separated; the first one is the URL |
| `nextcloud_service_trusted_proxies` | RFC1918, link-local | The proxy's traffic arrives through the host |
| `nextcloud_service_php_max_children` | `8` | php-fpm workers |
| `nextcloud_service_php_memory_limit` | `512M` | PHP limit per worker |
| `nextcloud_service_php_upload_limit` | `15G` | PHP and nginx body limit |
| `nextcloud_service_db_dump_retention_days` | `30` | Dump age before pruning |
| `nextcloud_service_apps` | `[admin_audit]` | Apps to enable; the file activity panels need `admin_audit` |
| `nextcloud_service_config` | see defaults | Keys set on every run |

## Specifics

- The role writes nothing into `config/` before the first start. The image
  copies `apps.config.php` (`apps_paths`) only into an empty directory;
  without it, apps land in `apps/`, which an upgrade wipes.
- `occ config:import` sets `nextcloud_service_config` on every run. The image
  applies `NEXTCLOUD_TRUSTED_DOMAINS` at the first install only.
- `data/custom_apps` is a nested subvolume, so apps and Recognize models stay
  out of backups. Its mode is `0755`, because nginx must traverse it.
- The passwords are podman secrets, read at the first start only.
- Nextcloud takes the client address from `X-Real-IP` alone, because a client
  can write `X-Forwarded-For`.
- nginx, php-fpm, Nextcloud and crond log to syslog through `/dev/log`, so
  each line keeps its own ident and severity. Container stdout and stderr
  carry only `info` and `err`. Nextcloud has no stdout log type: `errorlog`
  writes to the php-fpm worker's stderr, which php-fpm discards.
- The nginx access log has few JSON fields: syslog cuts a line at 1024 bytes.
  It omits the Referer and `$remote_user`, which can carry a share token.
- `monitoring/alloy-redact.txt` has one pattern per `{token}` route in
  `appinfo/routes.php`, plus the audit log's `token "…"`.
- `monitoring/alloy-drop.txt` drops Nextcloud's info line about a config key
  that an app's lexicon misses.
- `nextcloud-recognize` runs the five `Classify*Job` classes with
  `memory_limit=1G`, low-memory batch sizes and `concurrency.enabled=false`,
  so a classify job that cron takes returns at once while the worker is busy.
- A job whose process dies keeps `reserved_at` in `oc_jobs` for 12 hours.
  Nothing clears it, because a timer could free a job that still runs.
- The snapshot unit `Wants=` and `After=` the dump, so both run in one
  transaction. The dump has no timer.

## Custom image

`containers/Containerfile` adds ffmpeg, ghostscript, the helper scripts, a
php-fpm pool drop-in and two `config.php` drop-ins to `nextcloud:<major>-fpm`.
The entrypoint installs Nextcloud only for the command `php-fpm`, so the helper
containers pass their script. `.github/workflows/build.yml` builds and signs
each major, and rebuilds when the base image changes.

## Alerts

| Alert | Severity | Fires when |
|---|---|---|
| `NextcloudDatabasePanic` | critical | PostgreSQL logged `PANIC` |
| `NextcloudFatal` | critical | Nextcloud logged level 4 |
| `NextcloudCronStale` | warning | No `cron.php` start in 30 min |
| `NextcloudErrors` | warning | More than 20 errors in 1 h |
| `Nextcloud5xx` | warning | Over 5 % of over 50 requests are 5xx in 10 min |
| `NextcloudBruteForce` | warning | Over 10 failed logins from one address in 15 min |

## Role contract

The contract is in `home-server-template/README.md`. `vars/main.yml` sets
`quadlet_service_pod: nc`, because the pod file is `nc.pod`.

## LLM coding tools

This project is developed with LLM-based coding tools. They write most of the
code and documentation. The maintainer sets the goals and the design, reviews
every change and is responsible for it. Changes are tested on a VM before they
reach a host.

## License

MIT
