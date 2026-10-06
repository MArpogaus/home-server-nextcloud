# home-server-nextcloud

This project deploys Nextcloud as the rootless Podman pod `nextcloud` and builds
its signed app image. `home-server-bunker` puts the pod on the internet.

| Container | Job | Default memory ceiling |
|---|---|---|
| nextcloud-db | PostgreSQL, tuned for an SSD host | 768M |
| nextcloud-redis | Cache and file locks, memory only, capped at 3/4 of its ceiling | 128M |
| nextcloud-app | PHP-FPM, custom image | 2G |
| nextcloud-web | nginx; `status.php` health check | 128M |
| nextcloud-cron | `cron.php` every 5 min | 2G |
| nextcloud-preview | `preview:pre-generate` every 10 min, 1 CPU | 2G |
| nextcloud-recognize | Recognize classifier worker, 3 CPUs | 3G |
| nextcloud-push | `notify_push` | 128M |

## Configuration

The service follows the configuration interface in
`home-server-template/README.md`, "Configuration interface".
`ansible-role/nextcloud_service/defaults/main.yml` has the full list.

| Variable | Default | Controls |
|---|---|---|
| `nextcloud_service_hostname` | required | The public hostname; the URL and the first trusted domain |
| `nextcloud_service_db_password`, `_admin_password` | required | Podman secrets |
| `nextcloud_service_config` | `{}` | `config.php` keys (`system`) and app settings (`apps`), merged over `nextcloud_service_config_defaults` |
| `nextcloud_service_memory` | `{}` | Memory ceilings per container, merged over the table above |
| `nextcloud_service_admin_user` | `admin` | Admin of the first install |
| `nextcloud_service_php_max_children` | `8` | php-fpm workers |
| `nextcloud_service_php_memory_limit` | `512M` | PHP limit per worker |
| `nextcloud_service_php_upload_limit` | `15G` | PHP and pod nginx body limit; BunkerWeb has its own `MAX_CLIENT_SIZE` |
| `nextcloud_service_db_dump_retention_days` | `30` | Dump age before pruning |
| `nextcloud_service_apps` | `[admin_audit, notify_push, previewgenerator, recognize]` | Apps to install or enable; the file activity panels need `admin_audit`, the job containers the other three. An override replaces the list, so it must list them too |
| `nextcloud_service_*_image` | see `defaults/main.yml` | The images |

The config can change every key, including the URL. More trusted domains: set
`system.trusted_domains` in `nextcloud_service_config`. A list replaces the
default list. The preview sizes and the Recognize batch sizes are app settings
under `apps`; every deploy sets each with `occ config:app:set`, which keeps the
type that an app stored.

The app's memory ceiling (2G) is the PHP budget. `max_children` ×
`memory_limit` can pass it; when the workers, the opcache and `/tmp` together
reach it, the kernel kills the largest worker and its request answers 502.

## Specifics

- The job containers (cron, preview, recognize, push) run with `RunInit=true`,
  `StopSignal=SIGTERM` and `SuccessExitStatus=143`: a shell or crond as PID 1
  ignores the image's `SIGQUIT`. cron runs `busybox crond -S`, because the
  image's `/cron.sh` opens `/dev/stdout` by path. nginx starts with
  `-e stderr`, because it opens its built-in log path before it reads the
  config.
- The role writes nothing into `config/` before the first start. The image
  copies `apps.config.php` (`apps_paths`) only into an empty directory;
  without it, apps land in `apps/`, which an upgrade wipes.
- `data/custom_apps` is a nested subvolume, so apps and Recognize models stay
  out of backups. Its mode is `0755`, because nginx must traverse it.
- The passwords are Podman secrets, read at the first start only.
- Nextcloud takes the client address from `X-Real-IP` alone, because a client
  can write `X-Forwarded-For`.
- nginx, php-fpm, Nextcloud and crond log to syslog through `/dev/log`, so
  each line keeps its own ident and severity. Container stdout and stderr
  carry only `info` and `err`. Nextcloud has no stdout log type: `errorlog`
  writes to the php-fpm worker's stderr, which php-fpm discards.
- The nginx access log has few JSON fields: syslog cuts a line at 1024 bytes.
  It omits the Referer and `$remote_user`, which can carry a share token.
- `monitoring/alloy-redact.txt` has one line with an alternative per `{token}`
  route in `appinfo/routes.php`, and a second line for the audit log's
  `token "…"`.
- `monitoring/alloy-drop.txt` drops Nextcloud's info line about a config key
  that an app's lexicon misses.
- `nextcloud-recognize` runs the five `Classify*Job` classes with
  `memory_limit=1536M`. The batch sizes in `apps.recognize` fit its 3G
  ceiling, and `concurrency.enabled` is `false`.
  A classify job that cron takes then returns at once while the worker is busy.
- Nextcloud rounds a preview request up to a power of 4. The Memories grid
  asks for 339 to 909 pixels and reads the 1024 version, so
  `apps.previewgenerator` sets 64, 256, 1024 and 4096.
- `system.enabledPreviewProviders` limits previews to images, HEIC, TIFF and
  videos. PDF, text and office files get none.
- A job whose process dies keeps `reserved_at` in `oc_jobs` for 12 hours. Every
  pod restart kills the Recognize worker, so the worker script unlocks the
  classify jobs before the worker starts. Nothing clears other jobs, because a
  timer could free a job that still runs.
- The snapshot unit `Wants=` and `After=` the dump, so both run in one
  transaction. The dump has no timer.

## Custom image

`containers/Containerfile` adds ffmpeg, the helper scripts, a php-fpm pool
drop-in and larger opcache limits to `nextcloud:<major>-fpm`. The entrypoint
installs Nextcloud only for the command `php-fpm`, so the helper containers pass
their script. After an upgrade, the entrypoint runs the `post-upgrade` hook. It
updates the mimetypes of the file cache and adds missing indices, columns and
primary keys. `.github/workflows/build.yml` builds and signs each major in
`versions`, and rebuilds when the base image changes. `main` publishes
`:<major>` and `dev` publishes `:<major>-dev`; a host runs `-dev` only when its
vars set that tag. The major in `nextcloud_service_app_image` must be in
`versions`, or the host pulls a tag that CI never published. `cosign.pub`
verifies the signature. `home-server/ignition/config.bu.template` embeds the
same key for the host's `policy.json`, so a new key goes into both.

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

The contract is in `home-server-template/README.md`.

## LLM coding tools

LLM-based coding tools write most of the code and documentation of this
project. The maintainer sets the goals and the design, reviews every change and
is responsible for it. Each change runs on a VM before it reaches a host.

## License

MIT
