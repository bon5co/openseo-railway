# OpenSEO for Railway.
#
# Two things this image does that the upstream self-host image cannot do for
# itself:
#
#   1. It builds the app AT IMAGE BUILD TIME. Upstream's docker-entrypoint.sh
#      runs `pnpm run build` on every container start and skips it only when
#      `dist/.openseo-build-env` matches the current build-relevant env. `dist`
#      lives in the container filesystem, never on the volume, so on Railway
#      every deploy and every restart starts a fresh container with no build
#      output and pays the full ~7,400-module SSR build before it serves a
#      single request (measured cold: 119s to a healthy /api/health, with the
#      build alone holding >1.4 GiB). Baking the build and the fingerprint here
#      turns that into "Reusing existing build (build-relevant env unchanged)".
#      A deployer who changes AUTH_MODE or a VITE_* value still gets a correct
#      rebuild at boot -- the fingerprint mechanism is preserved, not disabled.
#   2. It puts a gate in front. In AUTH_MODE=local_noauth (the only mode Docker
#      self-hosting supports without Cloudflare Access) OpenSEO injects the
#      local admin for every request and checks nothing, and `POST /mcp` is
#      routed to the same first-party context -- see
#      src/server/mcp/transport.ts:handleSelfHostedOpenSeoMcpRequest. On a
#      public URL that is an anonymous key to the deployer's DataForSEO
#      credits. The gate here covers the UI with a password AND covers /mcp
#      with a bearer token, so agents still work.
FROM ghcr.io/every-app/open-seo:v0.1.3

USER root

# nginx = the gate. gettext-base = envsubst for its config template.
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Baked, NOT published as template variables. templateGenerate keeps a
# variable's defaultValue only when the live value is a Railway expression;
# literals are dropped and the variable publishes as a blank REQUIRED field on
# the deploy form. AUTH_MODE and VITE_SHOW_DEVTOOLS additionally feed the build
# fingerprint below, so they have to be identical here and at runtime.
ENV CLOUDFLARE_INCLUDE_PROCESS_ENV=true \
    AUTH_MODE=local_noauth \
    VITE_SHOW_DEVTOOLS=false \
    OPENSEO_APP_PORT=3001 \
    OPENSEO_ADMIN_USER=admin \
    OPENSEO_MAX_BODY_SIZE=25m \
    OPENSEO_RATE=20r/s \
    OPENSEO_RATE_BURST=60

# The build, and the fingerprint that tells upstream's entrypoint to keep it.
# The env expression is copied verbatim from docker-entrypoint.sh; if upstream
# ever changes its prefix list, this file writes a stale fingerprint and the
# container rebuilds at boot -- slow, but never wrong.
RUN set -eu; \
    pnpm run build; \
    FINGERPRINT="$(env | grep -E '^(VITE_|AUTH_MODE|BYPASS_EMAIL_VERIFICATION|POSTHOG_PUBLIC_KEY|POSTHOG_HOST|TURNSTILE_SITE_KEY|POSTHOG_SOURCEMAPS)' | sort | sha256sum | cut -d' ' -f1)"; \
    test -n "$FINGERPRINT"; \
    printf '%s' "$FINGERPRINT" > dist/.openseo-build-env; \
    echo "baked build fingerprint: $FINGERPRINT"; \
    cp -a /app/.wrangler /app/.wrangler-baked

# The build writes `.wrangler/deploy/config.json`, which @cloudflare/vite-plugin
# reads while `vite preview` resolves its config -- and `/app/.wrangler` is the
# volume mount point. A Docker named volume seeds itself from the image, so this
# is invisible locally; Railway bind-mounts an EMPTY directory over it and the
# app dies on `ENOENT: /app/.wrangler/deploy/config.json` before it ever listens.
# The entrypoint restores it from the copy above on every boot.

# A writable scratch dir that does not depend on the runtime uid: Railway's
# container could not create files under /tmp.
RUN mkdir -p /run/openseo && chmod 1777 /run/openseo

COPY nginx.conf.template /etc/openseo/nginx.conf.template
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Railway injects PORT into every service and its HTTP healthcheck dials the
# INJECTED port rather than the domain's target port, so the gate is what
# listens there and the app is pinned to OPENSEO_APP_PORT behind it.
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
