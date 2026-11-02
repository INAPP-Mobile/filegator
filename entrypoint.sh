#!/bin/bash
# FileGator Railway wrapper entrypoint.
#
# Why a wrapper at all (house style: bake constants, keep the deploy
# form zero-field, survive Railway's root-owned volumes):
# - PORT: Railway injects PORT, but the upstream image's Apache
#   configs literally contain "Listen ${APACHE_PORT}" (its Dockerfile
#   sed used single quotes, so the variable survived build time
#   unexpanded). Apache 2.4 expands ${VAR} from the process
#   environment, so this script exports APACHE_PORT=$PORT before
#   starting Apache (with literal-8080 seds as a fallback for a
#   future upstream that bakes a number instead). Without this,
#   Apache would listen on the image default 8080 while Railway's
#   healthcheck and public proxy probe $PORT.
# - MPM: the upstream image ships BOTH mpm_event and mpm_prefork
#   enabled, which kills Apache at startup with AH00534 "More than
#   one MPM loaded". mod_php requires prefork, so this script
#   disables mpm_event before starting Apache.
# - ONE VOLUME, TWO DIRS: upstream declares VOLUME for both
#   /var/www/filegator/repository (user files) and
#   /var/www/filegator/private (users.json, logs, sessions, tmp), but
#   Railway allows one volume per service. This script puts both dirs
#   under the single /data volume and symlinks them into place, so a
#   redeploy never wipes users or files. First-boot content (the
#   .htaccess, logs/sessions/tmp dirs, users.json.blank) is copied
#   from the image into /data/private before symlinking.
# - ADMIN PASSWORD: upstream's first run copies users.json.blank to
#   users.json, leaving the well-known default admin/admin123. When
#   ADMIN_PASSWORD is set (the template generates one) and this volume
#   has never been seeded, the admin entry's bcrypt hash is replaced
#   with a hash of ADMIN_PASSWORD and a marker is written. The marker
#   is what makes this safe: a deployer who later changes their
#   password in the FileGator UI is never reset by a redeploy, and
#   changing ADMIN_PASSWORD after first boot does NOT change the
#   password (change it in the UI instead). With ADMIN_PASSWORD
#   unset, the upstream default stands and the log says so.
# - CSRF KEY: upstream's sample config ships csrf_key "123456" for
#   everyone. This script replaces it with a fresh random value on
#   every boot (configuration.php lives in the image, not the volume,
#   so each boot re-randomizes; sessions live in /tmp-equivalent
#   paths anyway, so nothing valid is invalidated beyond a restart).
# - SESSIONS: the sample config leaves the session save path at the
#   system default (/tmp, lost on restart). This script points it at
#   private/sessions (on the volume via the symlink) so logins survive
#   a container restart.
# - USER root: Railway mounts /data root-owned; this script runs as
#   root, prepares /data, chowns it to www-data, and then starts
#   Apache (master as root, workers as www-data, the standard
#   php-apache shape). Upstream runs as www-data, which would
#   crash-loop on EACCES writing to a root-owned volume.
set -e

APP=/var/www/filegator
PORT="${PORT:-8080}"

# 1. Apache listen port -> Railway's injected PORT.
# Upstream's build-time sed used single quotes, so ports.conf and the
# vhost literally contain "Listen ${APACHE_PORT}" / "<VirtualHost
# *:${APACHE_PORT}>" — Apache 2.4 expands ${VAR} from the process
# environment, and the image sets APACHE_PORT=8080. Exporting
# APACHE_PORT=$PORT therefore retargets Apache onto Railway's port
# with no file rewrite. The seds below are a fallback for a future
# upstream that bakes a literal 8080 instead.
export APACHE_PORT="${PORT}"
sed -i "s/^Listen 8080/Listen ${PORT}/" /etc/apache2/ports.conf
sed -i "s/\*:8080/*:${PORT}/" /etc/apache2/sites-available/000-default.conf

# 1b. MPM conflict (proven 2026-11-02 on Railway): the upstream image
# ships BOTH mpm_event and mpm_prefork enabled in mods-enabled, so
# Apache dies at startup with AH00534 "More than one MPM loaded".
# mod_php requires prefork (it is not thread-safe), so disable event.
a2dismod -q mpm_event || true

# 2. Wire the single /data volume under both upstream data dirs.
mkdir -p /data/repository /data/private
for dir in repository private; do
  if [ ! -L "$APP/$dir" ]; then
    if [ -d "$APP/$dir" ]; then
      # Seed /data/<dir> from the image only when it is still empty,
      # so a fresh volume gets the upstream defaults and an existing
      # volume is never overwritten.
      if [ -z "$(ls -A "/data/$dir" 2>/dev/null)" ]; then
        cp -a "$APP/$dir/." "/data/$dir/" 2>/dev/null || true
      fi
      rm -rf "$APP/$dir"
    fi
    ln -s "/data/$dir" "$APP/$dir"
  fi
done
mkdir -p /data/private/logs /data/private/sessions /data/private/tmp

# 3. First-run users file: upstream's JsonFile adapter copies
#    users.json.blank -> users.json on first use; do it here so the
#    admin-password seeding below always has a file to edit.
if [ ! -f /data/private/users.json ] && [ -f /data/private/users.json.blank ]; then
  cp /data/private/users.json.blank /data/private/users.json
fi

# 4. Harden configuration.php (image copy, re-applied every boot).
php -r '
$c = file_get_contents("/var/www/filegator/configuration.php");
$c = str_replace(
  "\$save_path = null; // use default system path",
  "\$save_path = __DIR__.\x27/private/sessions\x27;",
  $c
);
$key = bin2hex(random_bytes(16));
$c = preg_replace(
  "/\x27csrf_key\x27 => \"[^\"]*\"/",
  "\x27csrf_key\x27 => \"$key\"",
  $c
);
file_put_contents("/var/www/filegator/configuration.php", $c);
'

# 5. Seed the admin password exactly once per volume.
if [ -n "$ADMIN_PASSWORD" ] && [ ! -f /data/.admin-seeded ] && [ -f /data/private/users.json ]; then
  ADMIN_PASSWORD="$ADMIN_PASSWORD" php -r '
$f = "/data/private/users.json";
$u = json_decode(file_get_contents($f), true);
if (isset($u["1"])) {
  $u["1"]["password"] = password_hash(getenv("ADMIN_PASSWORD"), PASSWORD_BCRYPT);
  file_put_contents($f, json_encode($u, JSON_UNESCAPED_SLASHES));
  touch("/data/.admin-seeded");
}
'
  echo "FileGator: admin password seeded from ADMIN_PASSWORD."
elif [ -z "$ADMIN_PASSWORD" ]; then
  echo "FileGator: WARNING ADMIN_PASSWORD unset - default admin/admin123 active; change it in the UI immediately."
fi

chown -R www-data:www-data /data

if command -v docker-php-entrypoint >/dev/null 2>&1; then
  exec docker-php-entrypoint apache2-foreground
else
  exec apache2-foreground
fi
