#!/bin/sh
# OpenSEO on Railway.
#
# Order of business:
#   1. Give the app a private port and keep Railway's injected $PORT for the
#      gate, because the edge healthcheck dials the injected port.
#   2. Default ALLOWED_HOST to the deployment's own public domain. vite preview
#      refuses any Host header that is not in that list, and an empty list
#      means the public URL answers "Blocked request" on every page.
#   3. Refuse to start without a UI password. In local_noauth mode OpenSEO has
#      no login of its own, so an ungated public deploy is an open admin
#      console holding the deployer's DataForSEO credentials.
#   4. Start the app, then hand PID 1 to nginx.
set -eu

log() { echo "[railway-entrypoint] $*"; }

LISTEN_PORT="${PORT:-8080}"
APP_PORT="${OPENSEO_APP_PORT:-3001}"
DATA_DIR=/app/.wrangler

# The app must not see Railway's injected PORT -- nginx owns it.
export PORT="$APP_PORT"
export OPENSEO_APP_PORT="$APP_PORT"

export ALLOWED_HOST="${ALLOWED_HOST:-${RAILWAY_PUBLIC_DOMAIN:-}}"
if [ -z "$ALLOWED_HOST" ]; then
    log "WARNING: neither ALLOWED_HOST nor RAILWAY_PUBLIC_DOMAIN is set; vite preview will reject requests that arrive with a hostname"
else
    log "allowed host: $ALLOWED_HOST"
fi

# --- volume ---------------------------------------------------------------
# This image runs as root and Railway mounts volumes as uid 0, so there is no
# ownership repair to do -- but a container that logs EACCES and keeps serving
# looks exactly like one that persists, so prove the mount instead of assuming
# it. /app/.wrangler is the whole database: D1 (projects, keywords, rank
# history, the local admin account), KV and R2 all live under it.
mkdir -p "$DATA_DIR"
if : > "$DATA_DIR/.railway-write-test" 2>/dev/null; then
    rm -f "$DATA_DIR/.railway-write-test"
    log "volume $DATA_DIR owner=$(stat -c %u:%g "$DATA_DIR") writable=yes"
else
    log "ERROR: volume $DATA_DIR is NOT writable (owner=$(stat -c %u:%g "$DATA_DIR")). Every project, keyword and rank check will be lost on the next deploy."
fi

# --- gate credentials -----------------------------------------------------
ADMIN_USER="${OPENSEO_ADMIN_USER:-admin}"
if [ -z "${OPENSEO_ADMIN_PASSWORD:-}" ]; then
    log "ERROR: OPENSEO_ADMIN_PASSWORD is empty."
    log "OpenSEO in Docker mode runs AUTH_MODE=local_noauth: it has no login of its own and treats every"
    log "caller as the admin. Starting without a gate would publish your DataForSEO account to the internet."
    log "Set OPENSEO_ADMIN_PASSWORD in the service variables and redeploy."
    exit 1
fi

HTPASSWD=/tmp/openseo.htpasswd
if hash="$(openssl passwd -apr1 "$OPENSEO_ADMIN_PASSWORD" 2>/dev/null)" && [ -n "$hash" ]; then
    printf '%s:%s\n' "$ADMIN_USER" "$hash" > "$HTPASSWD"
else
    # Fallback for an openssl without `passwd`. Unsalted, but the password is a
    # 24-character random secret and the file never leaves the container.
    printf '%s:{SHA}%s\n' "$ADMIN_USER" \
        "$(printf '%s' "$OPENSEO_ADMIN_PASSWORD" | openssl sha1 -binary | openssl base64)" > "$HTPASSWD"
fi
# nginx workers drop to www-data (Debian's compiled-in default) while this
# script runs as root, so a root-only file makes every gated request 500 with
# `open() "/tmp/openseo.htpasswd" failed (13: Permission denied)` -- and the
# cookie path still works, which makes it look like an app bug rather than a
# permissions one.
chmod 400 "$HTPASSWD"
chown www-data:www-data "$HTPASSWD" 2>/dev/null || chmod 444 "$HTPASSWD"

# Browsers do not reliably attach basic-auth credentials to a WebSocket
# handshake, and OpenSEO's in-app agent (SAM) talks over /agents/ via
# WebSocket. Cookies are always sent, so the gate hands out a cookie once the
# password has been accepted and takes either afterwards.
OPENSEO_GATE_COOKIE="$(printf '%s' "$OPENSEO_ADMIN_PASSWORD" | openssl sha256 -hex 2>/dev/null | awk '{print $NF}')"
[ -n "$OPENSEO_GATE_COOKIE" ] || OPENSEO_GATE_COOKIE="$(printf '%s' "$OPENSEO_ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)"
export OPENSEO_GATE_COOKIE

# An empty token must close /mcp, never open it: an unset variable is the one
# case where a match-anything value would hand the endpoint to the internet.
if [ -z "${OPENSEO_MCP_TOKEN:-}" ]; then
    log "OPENSEO_MCP_TOKEN is unset -- /mcp is closed. Set it to use OpenSEO's MCP server from an agent."
    OPENSEO_MCP_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
export OPENSEO_MCP_TOKEN

# --- app ------------------------------------------------------------------
log "starting OpenSEO on 127.0.0.1:${APP_PORT} (gate on ${LISTEN_PORT})"
sh /app/docker-entrypoint.sh &
APP_PID=$!

i=0
while [ "$i" -lt 300 ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "OpenSEO exited during startup"
        wait "$APP_PID" || exit $?
        exit 1
    fi
    if node -e "fetch('http://127.0.0.1:'+process.env.OPENSEO_APP_PORT+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
        log "OpenSEO answered /api/health after ${i}s"
        break
    fi
    sleep 1
    i=$((i + 1))
done

# --- gate -----------------------------------------------------------------
export PORT="$LISTEN_PORT"
envsubst '${PORT} ${OPENSEO_APP_PORT} ${OPENSEO_MAX_BODY_SIZE} ${OPENSEO_RATE} ${OPENSEO_RATE_BURST} ${OPENSEO_MCP_TOKEN} ${OPENSEO_GATE_COOKIE}' \
    < /etc/openseo/nginx.conf.template > /tmp/nginx.conf
mkdir -p /tmp/nginx
log "gate listening on ${LISTEN_PORT}: UI behind ${ADMIN_USER}:<OPENSEO_ADMIN_PASSWORD>, /mcp behind bearer OPENSEO_MCP_TOKEN, /api/health open for the Railway healthcheck"

# nginx becomes PID 1 below. If the app dies the container has to die with it,
# or the healthcheck keeps passing against a gate with nothing behind it.
(
    while kill -0 "$APP_PID" 2>/dev/null; do sleep 5; done
    log "OpenSEO exited, stopping the gate"
    kill 1 2>/dev/null || true
) &

exec nginx -c /tmp/nginx.conf -g 'daemon off;'
