#!/bin/bash
set -eu

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# app:getpath is the only honest test: it exits 1 when the app is not
# installed, and otherwise names the apps_paths entry it went into, which is
# custom_apps or apps depending on the config. `app:install` on an installed
# app exits 1, so guessing the directory turns into a crash loop.
APP_DIR="$(occ app:getpath notify_push 2>/dev/null || true)"
if [ -z "${APP_DIR}" ]; then
	occ app:install notify_push
	APP_DIR="$(occ app:getpath notify_push)"
fi
occ app:enable notify_push
BIN="${APP_DIR}/bin/${NOTIFY_PUSH_ARCH}/notify_push"

# Without this the app is installed but unusable, which looks like a crash loop.
if ! [ -x "$BIN" ]; then
	echo "ERROR: notify_push binary not found at ${BIN}" >&2
	echo "Present architectures: $(ls "${APP_DIR}/bin" 2>/dev/null || echo '<no bin directory>')" >&2
	echo "Set NOTIFY_PUSH_ARCH (currently '${NOTIFY_PUSH_ARCH}') to a listed value," >&2
	echo "or reinstall the app: occ app:remove notify_push && occ app:install notify_push" >&2
	exit 1
fi

exec runuser -u www-data -- "$BIN" /var/www/html/config/config.php
