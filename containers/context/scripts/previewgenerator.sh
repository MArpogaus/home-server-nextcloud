#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

occ app:install previewgenerator || occ app:enable previewgenerator

occ config:app:set --value="64 256" previewgenerator squareSizes
occ config:app:set --value="" previewgenerator widthSizes
occ config:app:set --value="" previewgenerator heightSizes
occ config:app:set --value="256 4096" previewgenerator fillWidthHeightSizes
occ config:app:set --value="256 4096" previewgenerator coverWidthHeightSizes
occ config:app:set --value="80" preview jpeg_quality
occ config:app:set --value=false --type=boolean previewgenerator job_disabled

# flock: a backlog pass outlasts the interval.
echo "*/10 * * * * flock -n /tmp/pre-generate.lock php /var/www/html/occ preview:pre-generate" \
	> /var/spool/cron/crontabs/www-data
exec busybox crond -f -l 0 -S
