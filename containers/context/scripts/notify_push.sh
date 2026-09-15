#!/bin/bash
set -eu

APP_DIR=/var/www/html/custom_apps/notify_push
BIN="${APP_DIR}/bin/${NOTIFY_PUSH_ARCH:-x86_64}/notify_push"

if ! [ -d "$APP_DIR" ]; then
	su www-data -ps /bin/sh -c "php occ app:install notify_push"
fi

su www-data -ps /bin/sh -c "php occ app:enable notify_push"

# The app store build ships prebuilt binaries under bin/<arch>/. If that
# directory is missing the app is installed but unusable, and the bare exit
# below would otherwise look like a silent crash loop.
if ! [ -x "$BIN" ]; then
	echo "ERROR: notify_push binary not found at ${BIN}" >&2
	echo "Present architectures: $(ls "${APP_DIR}/bin" 2>/dev/null || echo '<no bin directory>')" >&2
	echo "Set NOTIFY_PUSH_ARCH (currently '${NOTIFY_PUSH_ARCH:-x86_64}') to a listed value," >&2
	echo "or reinstall the app: occ app:remove notify_push && occ app:install notify_push" >&2
	exit 1
fi

exec su www-data -ps /bin/sh -c "$BIN /var/www/html/config/config.php"
