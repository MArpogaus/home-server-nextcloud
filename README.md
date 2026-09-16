# service-nextcloud

Nextcloud in a rootless Podman pod under the `nextcloud` user, managed via Ansible.

## Architecture

| Container | Image | Role |
|---|---|---|
| nextcloud-db | postgres:15 | Database (`pg_isready` health check) |
| nextcloud-redis | redis:7-alpine | Cache (`redis-cli ping`) |
| nextcloud-app | ghcr.io/marpogaus/nextcloud:31 (custom, fpm) | PHP-FPM |
| nextcloud-web | nginx:1-alpine | Serves the app; `status.php` health check covers the whole stack |
| nextcloud-cron | custom image | `cron.php` every 5 min + `preview:pre-generate` every 10 min |
| nextcloud-push | custom image | `notify_push` daemon |

The pod publishes `8080` on loopback only. Bunkerweb runs as a different
rootless user with its own container network, but it reaches the host through
pasta's host-loopback mapping, so it does not need this bound any wider. Inside
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
| `nextcloud_service_cron_extra_args` | `--memory=768M` |
| redis / web / push | 128M each |

### Secrets

DB credentials, admin user, trusted domains and PHP tuning come from
`secrets/vars.yml` via `nextcloud.env.j2`. `nextcloud_service_trusted_proxies` defaults
to RFC1918 + link-local because Bunkerweb's traffic arrives through the host.

## Backups

`pg-dumpall.timer` (23:55) dumps the DB into `data/db_dumps/` so the nightly
Btrfs snapshot (00:00, from `ansible-base`) is consistent. Dumps older than
30 days are pruned.

## Role Contract

Inherited from `site.yml`: `service_name`, `service_user`, `service_home`,
`service_repo`. File tasks notify `nextcloud quadlets changed`
(daemon-reload + pod restart only when something changed).

## Custom image

`containers/Containerfile` adds ffmpeg/ghostscript, `configure.sh` (PHP-FPM
pool sizing from `PHP_MAX_CHILDREN`), `notify_push.sh`, `previewgenerator.sh`
and config drop-ins. Built and signed by GitHub Actions, verified via cosign
policy on the host.

## Development

```bash
pre-commit install --install-hooks -t pre-commit -t commit-msg -t pre-push
```

Plain `pre-commit install` wires up only the pre-commit stage, so the
commitizen message and branch checks stay dormant. Hooks: shellcheck,
ansible-lint (which owns YAML style here), commitizen for conventional commits.
CI runs the same set on push and pull request. Actions are pinned to SHAs, and
dependabot updates actions and hook revisions weekly against `dev`.

## License

MIT
