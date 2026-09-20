#!/bin/bash
set -eu

APP_DIR=/var/www/html/custom_apps/notify_push
BIN="${APP_DIR}/bin/${NOTIFY_PUSH_ARCH}/notify_push"

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

if ! [ -d "$APP_DIR" ]; then
	occ app:install notify_push
fi
occ app:enable notify_push

# Without this the app is installed but unusable, which looks like a crash loop.
if ! [ -x "$BIN" ]; then
	echo "ERROR: notify_push binary not found at ${BIN}" >&2
	echo "Present architectures: $(ls "${APP_DIR}/bin" 2>/dev/null || echo '<no bin directory>')" >&2
	echo "Set NOTIFY_PUSH_ARCH (currently '${NOTIFY_PUSH_ARCH}') to a listed value," >&2
	echo "or reinstall the app: occ app:remove notify_push && occ app:install notify_push" >&2
	exit 1
fi

exec runuser -u www-data -- "$BIN" /var/www/html/config/config.php
