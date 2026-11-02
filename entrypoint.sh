#!/bin/bash
# FileGator Railway wrapper entrypoint.
#
# Why a wrapper at all (house style: bake constants, keep the deploy
# form zero-field, survive Railway's root-owned volumes):
# - PORT: Railway injects PORT, but the upstream image bakes Apache's
#   listen port at BUILD time (its Dockerfile sed-replaces 80 with
#   APACHE_PORT=8080 in ports.conf and the vhost). A runtime PORT
#   change therefore does nothing upstream, so this script rewrites
#   both files to $PORT before starting Apache. Without this,
#   Railway's healthcheck and public proxy would probe a port nothing
#   listens on.
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
sed -i "s/^Listen 8080/Listen ${PORT}/" /etc/apache2/ports.conf
sed -i "s/\*:8080/*:${PORT}/" /etc/apache2/sites-available/000-default.conf

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

# DEBUG (temporary, 2026-11-02): Apache fails with AH00534 "More than
# one MPM loaded" on Railway; print the ground truth before starting.
echo "DEBUG mods-enabled:"; ls /etc/apache2/mods-enabled/ | grep -i mpm || true
echo "DEBUG ports.conf:"; cat /etc/apache2/ports.conf
echo "DEBUG vhost:"; grep -i virtualhost /etc/apache2/sites-available/000-default.conf || true
apache2 -t 2>&1 || true

if command -v docker-php-entrypoint >/dev/null 2>&1; then
  exec docker-php-entrypoint apache2-foreground
else
  exec apache2-foreground
fi
