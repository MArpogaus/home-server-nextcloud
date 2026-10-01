#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

occ app:install recognize || occ app:enable recognize
APP_DIR="$(occ app:getpath recognize)"

# Low-memory profile; README, "Specifics".
for kv in concurrency.enabled=false faces.batchSize=50 imagenet.batchSize=20 landmarks.batchSize=20 movinet.batchSize=5; do
	occ config:app:set recognize "${kv%%=*}" --value="${kv##*=}"
done

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
	php -d memory_limit=1G /var/www/html/occ background-job:worker -v ${JOB_CLASSES}
