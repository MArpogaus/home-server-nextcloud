#!/bin/bash
set -xeuo pipefail

APP_DIR=/var/www/html/custom_apps/recognize

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# Same shape as previewgenerator.sh and notify_push.sh: the container owns its
# app, so a fresh host needs no manual step.
if ! [ -d "$APP_DIR" ]; then
	occ app:install recognize
elif [ "$(occ config:app:get recognize enabled)" = "no" ]; then
	occ app:enable recognize
fi

# A 200-face batch took node to 1.9 GB. Recognize's own low-memory profile.
for kv in faces.batchSize=50 imagenet.batchSize=20 landmarks.batchSize=20 movinet.batchSize=5; do
	occ config:app:set recognize "${kv%%=*}" --value="${kv##*=}"
done

# The models and the bundled node binary live inside the app directory. They
# are gigabytes, so they are fetched once, and again only if they are missing:
# a restore that carried the app but not its models lands here too.
if ! [ -x "$APP_DIR/bin/node" ] || ! find "$APP_DIR/models" -name '*.json' -print -quit 2>/dev/null | grep -q .; then
	occ recognize:download-models
fi

# Recognize classifies in background jobs, which otherwise run inside
# nextcloud-cron. A worker of its own keeps a memory-hungry ML job from taking
# cron.php down with it, and cron.php runs every other background job.
J="OCA\\Recognize\\BackgroundJobs\\"
JOB_CLASSES="${RECOGNIZE_JOB_CLASSES:-${J}ClassifyImagenetJob ${J}ClassifyFacesJob ${J}ClassifyLandmarksJob ${J}ClassifyMovinetJob ${J}ClassifyMusicnnJob}"

# Not `exec occ`: occ is a shell function, and exec needs a real binary.
# shellcheck disable=SC2086  # one argument per class
exec runuser -u www-data -- \
	php /var/www/html/occ background-job:worker -v ${JOB_CLASSES}
