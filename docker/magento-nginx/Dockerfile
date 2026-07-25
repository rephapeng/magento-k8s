# =============================================================================
# Magento web server image (Nginx, unprivileged).
# Serves static assets + media directly and proxies dynamic requests to the
# PHP-FPM container over 127.0.0.1:9000 (same Pod). Runs as non-root (uid 101),
# listening on 8080. The Magento codebase is mounted at runtime from the shared
# volume, so this image carries only the web-server config.
# =============================================================================
FROM nginxinc/nginx-unprivileged:1.27-alpine

# Magento vhost (replaces the default server block).
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080
