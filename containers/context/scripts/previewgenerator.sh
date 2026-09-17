#!/bin/bash
set -xeuo pipefail

occ() {
	runuser -u www-data -- php /var/www/html/occ "$@"
}

# 1. Install/Enable previewgenerator
if ! [ -d /var/www/html/custom_apps/previewgenerator ]; then
	occ app:install previewgenerator
	occ preview:generate-all &
elif [ "$(occ config:app:get previewgenerator enabled)" = "no" ]; then
	occ app:enable previewgenerator
fi

# 2. Apply configurations
occ config:app:set --value="64 256" previewgenerator squareSizes
occ config:app:set --value="" previewgenerator widthSizes
occ config:app:set --value="" previewgenerator heightSizes
occ config:app:set --value="256 4096" previewgenerator fillWidthHeightSizes
occ config:app:set --value="80" preview jpeg_quality
occ config:app:set --value=false --type=boolean previewgenerator job_disabled

# 3. Add preview job next to the image's cron.php entry, then run cron
CRONTAB=/var/spool/cron/crontabs/www-data
grep -q 'preview:pre-generate' "$CRONTAB" || \
	echo "*/10 * * * * php /var/www/html/occ preview:pre-generate" >> "$CRONTAB"
exec /cron.sh
