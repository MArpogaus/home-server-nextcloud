#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# The role installs the app and sets its batch sizes; a clean host gets it
# after this container starts.
until [ "$(occ config:app:get recognize enabled 2>/dev/null)" = yes ]; do sleep 30; done
APP_DIR="$(occ app:getpath recognize)"

# The models and the node binary live in the app directory, gigabytes fetched once.
if ! [ -x "$APP_DIR/bin/node" ] || ! find "$APP_DIR/models" -name '*.json' -print -quit 2>/dev/null | grep -q .; then
	occ recognize:download-models
fi

J="OCA\\Recognize\\BackgroundJobs\\"
JOB_CLASSES="${J}ClassifyImagenetJob ${J}ClassifyFacesJob ${J}ClassifyLandmarksJob ${J}ClassifyMovinetJob ${J}ClassifyMusicnnJob"

# Nextcloud keeps a job reserved for 12 h after its process dies, and every
# pod restart kills the worker. A classify job that cron runs at this moment
# returns at once, so freeing all classify jobs is safe.
# shellcheck disable=SC2016,SC2086  # PHP code, one argument per class
runuser -u www-data -- php -r '
	require "/var/www/html/lib/base.php";
	$jobs = \OCP\Server::get(\OCP\BackgroundJob\IJobList::class);
	foreach (array_slice($argv, 1) as $class) {
		foreach ($jobs->getJobsIterator($class, null, 0) as $job) {
			$jobs->unlockJob($job);
		}
	}' ${JOB_CLASSES}

# Not `exec occ`: occ is a shell function, and exec needs a real binary.
# shellcheck disable=SC2086  # one argument per class
exec runuser -u www-data -- \
	php -d memory_limit=1536M /var/www/html/occ background-job:worker ${JOB_CLASSES}
