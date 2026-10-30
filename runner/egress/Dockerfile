# arena-egress — the egress wall's tinyproxy, built NATIVE for this host (arm64 on the Mac box).
#
# Replaces vimagick/tinyproxy, which was amd64-only: under translation it segfaulted (exit 139) 31,136
# times on record, and each crash orphaned an anonymous volume (the image declared VOLUME /etc/tinyproxy).
# It also froze tinyproxy at 1.11.0 — inside CVE-2023-49606's range (1.10.0–1.11.1, a use-after-free in
# Connection-header parsing that an unauthenticated request can reach) — on the one component whose only
# client is the hostile-code sandbox. Alpine 3.22 ships 1.11.2, the fixed release.
#
# No VOLUME: the conf + allowlist are bind-mounted read-only by up-egress.sh, so nothing anonymous is
# created per container.
#
# up-egress.sh tags this image by a hash of THIS file and builds only when that tag is missing, so the
# image is frozen once built. To pick up a newer tinyproxy, change this file (e.g. bump the alpine tag):
# the new hash is a new tag, and the reuse test in up-egress.sh recreates the proxy on its next relaunch.
FROM alpine:3.22
RUN apk add --no-cache tinyproxy
# The package creates an unprivileged `tinyproxy` user; Port 8888 needs no root, and the conf sets no
# PidFile/LogFile, so the process never writes to the filesystem (up-egress.sh runs it --read-only).
USER tinyproxy
# -d is LOAD-BEARING: it keeps tinyproxy in the foreground as the container's main process. Daemonized,
# PID 1 exits at once, `docker wait` in run-egress.sh returns, and launchd relaunches every 10s — the
# same crash loop by a different route. Foreground also keeps its log on stdout (`docker logs egress`).
ENTRYPOINT ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
