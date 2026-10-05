#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# The role installs the app and sets its sizes; a clean host gets it after this
# container starts.
until occ app:getpath previewgenerator >/dev/null 2>&1; do sleep 30; done

# flock: a backlog pass outlasts the interval.
echo "*/10 * * * * flock -n /tmp/pre-generate.lock php /var/www/html/occ preview:pre-generate" \
	> /var/spool/cron/crontabs/www-data
exec busybox crond -f -l 0 -S
