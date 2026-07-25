# =============================================================================
# Magento application image  (PHP-FPM 8.3 + compiled Magento code)
# -----------------------------------------------------------------------------
# Multi-stage: `build` installs Magento via Composer and compiles it in
# production mode; `runtime` ships only the compiled app on a slim PHP-FPM base
# running as a non-root user.
#
# Package source: defaults to the Mage-OS public mirror, which serves the
# *identical* magento/* Open Source packages (same names, same versions, same
# archives) but needs NO authentication. That keeps the build reproducible for
# anyone cloning this repo without an Adobe Marketplace account. Point
# COMPOSER_REPO_URL at https://repo.magento.com/ to use the official repo
# instead; auth keys are then read from an OPTIONAL BuildKit secret, so they
# never end up in an image layer either way.
#
# Build:
#   DOCKER_BUILDKIT=1 docker build -t magento-app:2.4.7-p3 docker/magento-app
#   # official repo instead:
#   DOCKER_BUILDKIT=1 docker build \
#     --build-arg COMPOSER_REPO_URL=https://repo.magento.com/ \
#     --secret id=composer_auth,src=auth.json \
#     -t magento-app:2.4.7-p3 docker/magento-app
# =============================================================================
ARG PHP_VERSION=8.3
ARG MAGENTO_VERSION=2.4.7-p3
ARG COMPOSER_REPO_URL=https://mirror.mage-os.org/
# Pin the Debian suite: the runtime stage installs versioned runtime libs
# (libicu72, libzip4, ...) whose names are suite-specific. The floating
# `php:8.3-fpm` tag has since moved to trixie (libicu76/libzip5), which breaks
# the install. Pinning keeps the build reproducible.
ARG DEBIAN_SUITE=fpm-bookworm

# ---------- build stage ------------------------------------------------------
FROM php:${PHP_VERSION}-${DEBIAN_SUITE} AS build
ARG MAGENTO_VERSION
ARG COMPOSER_REPO_URL

# Build/runtime libraries needed by Magento's PHP extensions.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git unzip libzip-dev libicu-dev libxml2-dev libxslt1-dev \
      libpng-dev libjpeg-dev libfreetype6-dev libonig-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
      bcmath ctype gd intl pdo_mysql soap sockets sysvsem xsl zip opcache \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2.7 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html
ENV COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1

# Download Magento. The auth secret is OPTIONAL (required=false): the default
# Mage-OS mirror needs none, and it is only consulted when COMPOSER_REPO_URL
# points at an authenticated repository such as repo.magento.com.
RUN --mount=type=secret,id=composer_auth,target=/root/.composer/auth.json,required=false \
    composer create-project --no-interaction --no-progress \
      --repository-url="${COMPOSER_REPO_URL}" \
      "magento/project-community-edition=${MAGENTO_VERSION}" . \
 && composer clear-cache

# Register every module first: a fresh `composer create-project` ships no
# app/etc/config.php, and without it di:compile aborts with "modules are not
# enabled". This writes the module list only — it needs no DB.
RUN php bin/magento module:enable --all

COPY bin/build-scopes.php /usr/local/share/build-scopes.php

# Compile DI + deploy static content offline (no DB needed) => production mode.
# memory_limit=-1 is Magento's documented requirement for these two commands;
# the PHP default of 128M dies part-way through proxy generation. This applies
# to the BUILD stage only — the runtime pool is bounded by conf/php.ini.
#
# static-content:deploy needs to know which store views to render for. With no
# database it reads them from the `scopes` section of app/etc/config.php, which
# a fresh create-project does not have — hence the temporary inject/remove
# around it (see build-scopes.php).
RUN php -d memory_limit=-1 bin/magento setup:di:compile \
 && php /usr/local/share/build-scopes.php add \
 && php -d memory_limit=-1 bin/magento setup:static-content:deploy -f en_US \
 && php /usr/local/share/build-scopes.php remove \
 && rm -rf var/cache/* var/page_cache/* var/view_preprocessed/* generated/metadata/*.lock

# ---------- runtime stage ----------------------------------------------------
FROM php:${PHP_VERSION}-${DEBIAN_SUITE} AS runtime

# Only the SHARED libraries the extensions link against — no -dev headers and no
# toolchain, which is what keeps this stage slim. The extensions themselves are
# not recompiled here; they are copied from the build stage below (same base
# image => same PHP ABI), so the runtime never needs a compiler.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libzip4 libicu72 libxslt1.1 libpng16-16 libjpeg62-turbo libfreetype6 \
      default-mysql-client curl gettext-base procps \
    && rm -rf /var/lib/apt/lists/*

# Compiled extension binaries + their docker-php-ext-*.ini activation files.
COPY --from=build /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=build /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# Non-root runtime user (uid/gid 1000 => matches pod securityContext).
RUN groupadd -g 1000 magento && useradd -u 1000 -g magento -d /var/www/html -s /bin/bash magento

COPY conf/php.ini /usr/local/etc/php/conf.d/zz-magento.ini
COPY conf/www.conf /usr/local/etc/php-fpm.d/zz-www.conf
COPY bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY bin/magento-install.sh   /usr/local/bin/magento-install.sh
COPY bin/env.php.template      /usr/local/share/env.php.template
COPY bin/seed-product.php      /usr/local/share/seed-product.php
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/magento-install.sh

WORKDIR /var/www/html
COPY --from=build --chown=1000:1000 /var/www/html /var/www/html

USER magento
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["php-fpm", "-F"]
