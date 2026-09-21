#!/bin/bash
set -euo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# app:getpath exits 1 when the app is not installed; the directory it lands in
# is not always custom_apps.
if ! occ app:getpath previewgenerator >/dev/null 2>&1; then
	occ app:install previewgenerator
	occ preview:generate-all &
elif [ "$(occ config:app:get previewgenerator enabled)" = "no" ]; then
	occ app:enable previewgenerator
fi

occ config:app:set --value="64 256" previewgenerator squareSizes
occ config:app:set --value="" previewgenerator widthSizes
occ config:app:set --value="" previewgenerator heightSizes
occ config:app:set --value="256 4096" previewgenerator fillWidthHeightSizes
occ config:app:set --value="256 4096" previewgenerator coverWidthHeightSizes
occ config:app:set --value="80" preview jpeg_quality
occ config:app:set --value=false --type=boolean previewgenerator job_disabled

# This container runs previews only, so it owns the crontab; cron.php stays in
# nextcloud-cron.
echo "*/10 * * * * php /var/www/html/occ preview:pre-generate" > /var/spool/cron/crontabs/www-data
# Not /cron.sh: it logs to /dev/stdout, a socket under passthrough. syslog goes
# to the mounted /dev/log.
exec busybox crond -f -S
