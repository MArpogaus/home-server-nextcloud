#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# app:getpath exits 1 when the app is not installed and otherwise names the
# apps_paths entry it went into; the directory is not always custom_apps.
APP_DIR="$(occ app:getpath recognize 2>/dev/null || true)"
if [ -z "${APP_DIR}" ]; then
	occ app:install recognize
	APP_DIR="$(occ app:getpath recognize)"
elif [ "$(occ config:app:get recognize enabled)" = "no" ]; then
	occ app:enable recognize
fi

# Low-memory profile; README, Recognize.
for kv in concurrency.enabled=false faces.batchSize=50 imagenet.batchSize=20 landmarks.batchSize=20 movinet.batchSize=5; do
	occ config:app:set recognize "${kv%%=*}" --value="${kv##*=}"
done

# The models and the bundled node binary live inside the app directory. They
# are gigabytes, so they are fetched once, and again only if they are missing:
# a restore that carried the app but not its models lands here too.
if ! [ -x "$APP_DIR/bin/node" ] || ! find "$APP_DIR/models" -name '*.json' -print -quit 2>/dev/null | grep -q .; then
	occ recognize:download-models
fi

J="OCA\\Recognize\\BackgroundJobs\\"
JOB_CLASSES="${J}ClassifyImagenetJob ${J}ClassifyFacesJob ${J}ClassifyLandmarksJob ${J}ClassifyMovinetJob ${J}ClassifyMusicnnJob"

# Not `exec occ`: occ is a shell function, and exec needs a real binary.
# shellcheck disable=SC2086  # one argument per class
exec runuser -u www-data -- \
	php -d memory_limit=1G /var/www/html/occ background-job:worker -v ${JOB_CLASSES}
