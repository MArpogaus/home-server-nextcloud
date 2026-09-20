#!/bin/bash
set -eu

PHP_PATH=/usr/local/etc
FPM_POOL="${PHP_PATH}/php-fpm.d/www.conf"

FPMS=${PHP_MAX_CHILDREN}
PMaxSS=$((FPMS*2/3))
PMinSS=$((PMaxSS/2))
PStartS=$(((PMaxSS+PMinSS)/2))

sed -i "s/pm.max_children =.*/pm.max_children = $FPMS/"             "$FPM_POOL"
sed -i "s/pm.start_servers =.*/pm.start_servers = $PStartS/"        "$FPM_POOL"
sed -i "s/pm.min_spare_servers =.*/pm.min_spare_servers = $PMinSS/" "$FPM_POOL"
sed -i "s/pm.max_spare_servers =.*/pm.max_spare_servers = $PMaxSS/" "$FPM_POOL"

if [ -n "${PHP_MAX_REQUESTS:-}" ]; then
    sed -i "s/;pm.max_requests = 500/pm.max_requests = $PHP_MAX_REQUESTS/" "$FPM_POOL"
fi

sed -i "s/;emergency_restart_threshold =.*/emergency_restart_threshold = ${PHP_EMERGENCY_RESTART_THRESHOLD}/" "$PHP_PATH/php-fpm.conf"
sed -i "s/;emergency_restart_interval =.*/emergency_restart_interval = ${PHP_EMERGENCY_RESTART_INTERVAL}/"   "$PHP_PATH/php-fpm.conf"
sed -i "s/;process_control_timeout =.*/process_control_timeout = ${PHP_PROCESS_CONTROL_TIMEOUT}/"           "$PHP_PATH/php-fpm.conf"

# conf.d drop-in: the image ships no php.ini. memory_limit and upload_limit
# come from the image's nextcloud.ini via PHP_MEMORY_LIMIT and PHP_UPLOAD_LIMIT.
{
    echo "max_execution_time = ${PHP_MAX_EXECUTION_TIME}"
    echo "max_input_time = ${PHP_MAX_EXECUTION_TIME}"
    echo "max_file_uploads = ${PHP_MAX_FILE_UPLOADS}"
    echo "allow_url_fopen = Off"
    echo "display_errors = Off"
    echo "expose_php = Off"
    echo "session.use_strict_mode = On"
    echo "session.cookie_httponly = On"
    echo "session.cookie_secure = On"
    echo "allow_url_include = Off"
} > "$PHP_PATH/php/conf.d/99-nextcloud-recommended.ini"

exec "$@"
