#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# The role installs the app; a clean host gets it after this container starts.
echo "Waiting for the app notify_push"
# enabled holds yes, no, or a JSON list of groups.
until v="$(occ config:app:get notify_push enabled 2>/dev/null)" && [ -n "$v" ] && [ "$v" != no ]; do sleep 30; done
APP_DIR="$(occ app:getpath notify_push)"
BIN="${APP_DIR}/bin/$(uname -m)/notify_push"

if ! [ -x "$BIN" ]; then
	echo "ERROR: notify_push binary not found at ${BIN}" >&2
	echo "Reinstall the app: occ app:remove notify_push && occ app:install notify_push" >&2
	exit 1
fi

exec runuser -u www-data -- "$BIN" /var/www/html/config/config.php
