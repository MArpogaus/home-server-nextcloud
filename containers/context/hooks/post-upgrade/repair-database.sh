#!/bin/sh
# occ upgrade leaves the indices, columns and mimetype fixes of the new
# version to these commands. Not maintenance:repair: it reruns every app's
# install steps, and Recognize then downloads its TensorFlow libraries again.
# No set -e: a failed hook stops the entrypoint, and the image that podman
# auto-update rolls back to refuses the newer data.
php /var/www/html/occ maintenance:mimetype:update-db --repair-filecache
php /var/www/html/occ db:add-missing-indices
php /var/www/html/occ db:add-missing-columns
php /var/www/html/occ db:add-missing-primary-keys
exit 0
