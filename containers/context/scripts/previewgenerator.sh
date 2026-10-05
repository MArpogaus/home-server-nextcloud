#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# The role installs the app and sets its sizes; a clean host gets it after this
# container starts.
echo "Waiting for the app previewgenerator"
# enabled holds yes, no, or a JSON list of groups.
until v="$(occ config:app:get previewgenerator enabled 2>/dev/null)" && [ -n "$v" ] && [ "$v" != no ]; do sleep 30; done

# flock: a backlog pass outlasts the interval.
echo "*/10 * * * * flock -n /tmp/pre-generate.lock php /var/www/html/occ preview:pre-generate" \
	> /var/spool/cron/crontabs/www-data
exec busybox crond -f -l 0 -S
