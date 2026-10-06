#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

echo "Waiting for the app previewgenerator"
until v="$(occ config:app:get previewgenerator enabled 2>/dev/null)" && [ -n "$v" ] && [ "$v" != no ]; do sleep 30; done

echo "*/10 * * * * flock -n /tmp/pre-generate.lock php /var/www/html/occ preview:pre-generate" \
	> /var/spool/cron/crontabs/www-data
exec busybox crond -f -l 0 -S
