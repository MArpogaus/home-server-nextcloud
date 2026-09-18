#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# Same shape as previewgenerator.sh and notify_push.sh: the container owns its
# app. Models are not downloaded here, because that is gigabytes and belongs in
# a deliberate step: occ recognize:download-models
if ! [ -d /var/www/html/custom_apps/recognize ]; then
	occ app:install recognize
elif [ "$(occ config:app:get recognize enabled)" = "no" ]; then
	occ app:enable recognize
fi

# Recognize classifies in background jobs, which otherwise run inside
# nextcloud-cron. A worker of its own keeps a memory-hungry ML job from taking
# cron.php down with it, and cron.php runs every other background job.
JOB_CLASS="${RECOGNIZE_JOB_CLASS:-OCA\\Recognize\\BackgroundJobs\\ClassifierJob}"

exec occ background-job:worker -v "${JOB_CLASS}"
