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
| `nextcloud_service_cpu` | `{}` | CPU quotas per container, merged over `preview: 100%` and `recognize: 300%` |
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

- `data/custom_apps` is a nested subvolume, so apps and Recognize models stay
  out of backups.
- The passwords are Podman secrets, read at the first start only.
- Nextcloud takes the client address from `X-Real-IP`, which BunkerWeb sets.
- Postgres has the SSD and autovacuum part of the Nextcloud AIO tuning.
  `shared_buffers` (256 MB) and the pod's `/dev/shm` (256 MB) count against
  its memory ceiling.
- Redis holds the cache and the file locks in memory only. It evicts old keys
  at 3/4 of its memory ceiling.
- Before each snapshot, `pg_dumpall` writes the database into the service
  subvolume, so the snapshot holds a consistent copy.
- `nextcloud-recognize` runs the five `Classify*Job` classes with
  `memory_limit=1536M`. The batch sizes in `apps.recognize` fit its 3G
  ceiling, and `concurrency.enabled` is `false`.
- Nextcloud rounds a preview request up to a power of 4. The Memories grid
  asks for 339 to 909 pixels and reads the 1024 version, so
  `apps.previewgenerator` sets 64, 256, 1024 and 4096.
- `system.enabledPreviewProviders` limits previews to images, HEIC, TIFF and
  videos. PDF, text and office files get none.
- nginx, php-fpm, Nextcloud and crond log to syslog through `/dev/log`, so
  each line keeps its own ident and severity. The nginx access log omits the
  Referer and `$remote_user`, which can carry a share token.
- `monitoring/alloy-redact.txt` has one line with an alternative per `{token}`
  route in `appinfo/routes.php`, and a second line for the audit log's
  `token "…"`. `monitoring/alloy-drop.txt` drops Nextcloud's info line about a
  config key that an app's lexicon misses.

## Custom image

`containers/Containerfile` adds ffmpeg, the helper scripts, a php-fpm pool
drop-in and larger opcache limits to `nextcloud:<major>-fpm`. The entrypoint
installs Nextcloud only for the command `php-fpm`, so the helper containers pass
their script. After an upgrade, the entrypoint runs the `post-upgrade` hook. It
adds the new version's mimetypes and missing indices, columns and primary keys.
A failed command does not stop the start. JIT is off, as in Nextcloud AIO.
`.github/workflows/build.yml` builds and signs each major in `versions`, and
rebuilds when the base image changes. `main` publishes `:<major>` and `dev`
publishes `:<major>-dev`; a host runs `-dev` only when its vars set that tag.
The major in `nextcloud_service_app_image` must be in `versions`, or the host
pulls a tag that CI never published. `cosign.pub` verifies the signature.
`home-server/ignition/config.bu.template` embeds the same key for the host's
`policy.json`, so a new key goes into both.

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
