FROM php:8.2-cli
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev unzip \
    && docker-php-ext-install pdo_pgsql && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction
COPY . .
EXPOSE 3000
CMD ["php", "-S", "0.0.0.0:3000", "public/index.php"]
