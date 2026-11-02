# FileGator on Railway — wrapper around the pinned upstream image.
#
# Why a wrapper at all (house style: bake constants, keep the deploy
# form zero-field, and survive Railway's root-owned volumes):
# - PORT: Railway injects PORT, but upstream's configs literally
#   contain "Listen ${APACHE_PORT}" (its build-time sed used single
#   quotes, so the variable was never expanded at build time).
#   Apache 2.4 expands ${VAR} from the process environment, so
#   entrypoint.sh exports APACHE_PORT=$PORT before starting Apache.
# - MPM: upstream ships both mpm_event and mpm_prefork enabled, which
#   kills Apache at startup (AH00534); entrypoint.sh disables
#   mpm_event (mod_php requires prefork).
# - ONE VOLUME, TWO DIRS: upstream wants both repository/ (user files)
#   and private/ (users.json, logs, sessions) on disk, but Railway
#   allows one volume per service. entrypoint.sh puts both under the
#   single /data volume and symlinks them into place.
# - ADMIN PASSWORD: upstream's first run leaves the well-known
#   default admin/admin123. The template variable ADMIN_PASSWORD
#   (generated) replaces that hash exactly once per volume; later
#   password changes in the UI are never reset by a redeploy.
# - CSRF KEY: upstream's sample config ships csrf_key "123456" for
#   everyone; entrypoint.sh replaces it with a fresh random value on
#   every boot.
# - SESSIONS: pointed at private/sessions on the volume so logins
#   survive a container restart (upstream default is /tmp).
# - USER root: Railway mounts /data root-owned; the entrypoint runs
#   as root, prepares /data, chowns it to www-data, then starts
#   Apache (workers run as www-data as usual).
# - No Docker HEALTHCHECK: rely on Railway's external healthcheckPath
#   ("/" serves the Vue SPA shell unauthenticated, 200).
#
# Upstream: FileGator v7.16.8 (MIT), image pinned by manifest digest,
# verified 2026-11-02 via the Docker Hub API (amd64 image digest
# sha256:588fa79d5e7b32e21c97f8d1f9004609bac849b28405712b7ba3d242bb365fc8).

FROM filegator/filegator@sha256:1c8e795bb147db03c251bec127fc879aef16c45887a386c23be077ee6963da2e

USER root

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# No baked app constants beyond the entrypoint's own behavior: the
# admin password comes from the template variable, everything else
# (timezone UTC, 100 MB upload cap, chunked uploads, editable types)
# is upstream's default configuration.

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
