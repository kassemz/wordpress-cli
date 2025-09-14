# Using a Debian-based image to install the official MySQL client from repo.mysql.com
FROM php:8.3-cli-bookworm

# install wp-cli dependencies and official MySQL client
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        less \
        gnupg \
        vim \
        wget \
        ca-certificates \
    ; \
# Add MySQL official repository and key as requested
    wget -O- https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 | gpg --dearmor > /etc/apt/trusted.gpg.d/mysql-community.gpg; \
# Use the mysql-8.4 repository as requested
    echo "deb http://repo.mysql.com/apt/debian/ bookworm mysql-8.4-lts" > /etc/apt/sources.list.d/mysql.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mysql-client \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*;

RUN set -ex; \
    mkdir -p /var/www/html; \
    chown -R www-data:www-data /var/www/html
WORKDIR /var/www/html

# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN set -ex; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        $PHPIZE_DEPS \
        libfreetype6-dev \
        libicu-dev \
        libmagickwand-dev \
        libheif-dev \
        libavif-dev \
        libjpeg-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
    ; \
    \
    docker-php-ext-configure gd \
        --with-avif \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    ; \
    docker-php-ext-install -j "$(nproc)" \
        bcmath \
        exif \
        gd \
        intl \
        mysqli \
        zip \
    ; \

# https://pecl.php.net/package/imagick
    pecl install imagick-3.8.0; \
    docker-php-ext-enable imagick; \
    rm -r /tmp/pear; \
    \
# some misbehaving extensions end up outputting to stdout 🙈 (https://github.com/docker-library/wordpress/issues/669#issuecomment-993945967)
    out="$(php -r 'exit(0);')"; \
    [ -z "$out" ]; \
    err="$(php -r 'exit(0);' 3>&1 1>&2 2>&3)"; \
    [ -z "$err" ]; \
    \
    extDir="$(php -r 'echo ini_get("extension_dir");')"; \
    [ -d "$extDir" ]; \
# Fix: Replace scanelf with ldd-based dependency detection for Debian
    runDeps="$( \
        find "$extDir" -name '*.so' -exec ldd {} \; \
            | awk '/=>/ { print $1 }' \
            | sort -u \
            | xargs -r dpkg-query --search 2>/dev/null \
            | awk -F: '{ print $1 }' \
            | sort -u \
    )"; \
    if [ -n "$runDeps" ]; then \
        apt-get install -y --no-install-recommends $runDeps; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    ! { ldd "$extDir"/*.so | grep 'not found'; }; \
# check for output like "PHP Warning:   PHP Startup: Unable to load dynamic library 'foo' (tried: ...)
    err="$(php --version 3>&1 1>&2 2>&3)"; \
    [ -z "$err" ]

# set recommended PHP.ini settings
# excluding opcache due https://github.com/docker-library/wordpress/issues/407
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
        echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
        echo 'display_errors = Off'; \
        echo 'display_startup_errors = Off'; \
        echo 'log_errors = On'; \
        echo 'error_log = /dev/stderr'; \
        echo 'log_errors_max_len = 1024'; \
        echo 'ignore_repeated_errors = On'; \
        echo 'ignore_repeated_source = Off'; \
        echo 'html_errors = Off'; \
    } > /usr/local/etc/php/conf.d/error-logging.ini

# https://make.wordpress.org/cli/2018/05/31/gpg-signature-change/
# pub   rsa2048 2018-05-31 [SC]
#       63AF 7AA1 5067 C056 16FD   DD88 A3A2 E8F2 26F0 BC06
# uid           [ unknown] WP-CLI Releases <releases@wp-cli.org>
# sub   rsa2048 2018-05-31 [E]
ENV WORDPRESS_CLI_GPG_KEY 63AF7AA15067C05616FDDD88A3A2E8F226F0BC06

ENV WORDPRESS_CLI_VERSION 2.12.0
ENV WORDPRESS_CLI_SHA512 be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832

RUN set -ex; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gnupg \
        curl \
    ; \
    \
    curl -o /usr/local/bin/wp.gpg -fL "https://github.com/wp-cli/wp-cli/releases/download/v${WORDPRESS_CLI_VERSION}/wp-cli-${WORDPRESS_CLI_VERSION}.phar.gpg"; \
    \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$WORDPRESS_CLI_GPG_KEY"; \
    gpg --batch --decrypt --output /usr/local/bin/wp /usr/local/bin/wp.gpg; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" /usr/local/bin/wp.gpg; unset GNUPGHOME; \
    \
    echo "$WORDPRESS_CLI_SHA512 */usr/local/bin/wp" | sha512sum -c -; \
    chmod +x /usr/local/bin/wp; \
    \
    apt-get purge -y --auto-remove gnupg curl; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    wp --allow-root --version

VOLUME /var/www/html

CMD ["wp", "shell"]
