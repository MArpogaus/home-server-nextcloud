#!/bin/sh
# occ upgrade leaves the indices, columns and mimetype fixes of the new
# version to these commands.
set -e
php /var/www/html/occ maintenance:repair --include-expensive
php /var/www/html/occ db:add-missing-indices
php /var/www/html/occ db:add-missing-columns
php /var/www/html/occ db:add-missing-primary-keys
