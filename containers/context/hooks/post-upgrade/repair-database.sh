#!/bin/sh
php /var/www/html/occ maintenance:mimetype:update-db
php /var/www/html/occ db:add-missing-indices
php /var/www/html/occ db:add-missing-columns
php /var/www/html/occ db:add-missing-primary-keys
exit 0
