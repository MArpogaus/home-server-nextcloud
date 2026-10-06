#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

echo "Waiting for the app recognize"
until v="$(occ config:app:get recognize enabled 2>/dev/null)" && [ -n "$v" ] && [ "$v" != no ]; do sleep 30; done
APP_DIR="$(occ app:getpath recognize)"

if ! [ -x "$APP_DIR/bin/node" ] || ! find "$APP_DIR/models" -name '*.json' -print -quit 2>/dev/null | grep -q .; then
	occ recognize:download-models
fi

J="OCA\\Recognize\\BackgroundJobs\\"
JOB_CLASSES="${J}ClassifyImagenetJob ${J}ClassifyFacesJob ${J}ClassifyLandmarksJob ${J}ClassifyMovinetJob ${J}ClassifyMusicnnJob"

# shellcheck disable=SC2016,SC2086
runuser -u www-data -- php -r '
	require "/var/www/html/lib/base.php";
	$jobs = \OCP\Server::get(\OCP\BackgroundJob\IJobList::class);
	foreach (array_slice($argv, 1) as $class) {
		foreach ($jobs->getJobsIterator($class, null, 0) as $job) {
			$jobs->unlockJob($job);
		}
	}' ${JOB_CLASSES}

# shellcheck disable=SC2086
exec runuser -u www-data -- \
	php -d memory_limit=1536M /var/www/html/occ background-job:worker ${JOB_CLASSES}
