#!/bin/bash
set -ex

PHP_PATH=/usr/local/etc
FPM_POOL="${PHP_PATH}/php-fpm.d/www.conf"

# PHP-FPM optimization
FPMS=${PHP_MAX_CHILDREN:-20}
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

sed -i "s/;emergency_restart_threshold =.*/emergency_restart_threshold = ${PHP_EMERGENCY_RESTART_THRESHOLD:-10}/" "$PHP_PATH/php-fpm.conf"
sed -i "s/;emergency_restart_interval =.*/emergency_restart_interval = ${PHP_EMERGENCY_RESTART_INTERVAL:-1m}/"   "$PHP_PATH/php-fpm.conf"
sed -i "s/;process_control_timeout =.*/process_control_timeout = ${PHP_PROCESS_CONTROL_TIMEOUT:-10s}/"           "$PHP_PATH/php-fpm.conf"

# PHP settings (upstream entrypoint handles memory_limit, upload_limit)
# Uses conf.d drop-in instead of sed on php.ini (which may not exist)
{
    echo "max_execution_time = ${PHP_MAX_EXECUTION_TIME:-3600}"
    echo "max_input_time = ${PHP_MAX_INPUT_TIME:-3600}"
    echo "max_file_uploads = ${PHP_MAX_FILE_UPLOADS:-100}"
    echo "allow_url_fopen = Off"
    echo "display_errors = Off"
    echo "expose_php = Off"
    echo "session.use_strict_mode = On"
    echo "session.cookie_httponly = On"
    echo "session.cookie_secure = On"
    echo "allow_url_include = Off"
} > "$PHP_PATH/php/conf.d/99-nextcloud-recommended.ini"

echo executing default entrypoint
exec "$@"
