# sample-php-notes

The notes API in PHP (PDO, Predis, PHPUnit), with Postgres and Redis from `compose.yaml`.

**What it tests:**
- PHP detection from `composer.json`. PHP and Composer come from Debian packages, not mise.
- `composer.json` requires `ext-pdo_pgsql`, which isn't in those packages. The agent installs
  it with `airlock-install php-pgsql`, and AIrlock bakes it into the project's next image.

**What AIrlock should detect:**
- Packages: `php-cli`, `php-xml`, `php-mbstring`, `php-curl`, `php-zip`, `unzip`, `composer`
- Allowed hosts: `packagist.org`, `repo.packagist.org`. Composer downloads package archives
  from GitHub, so expect a blocked-host prompt for `codeload.github.com` the first time.
- Caches: `COMPOSER_CACHE_DIR` on the project's cache volume

**Prompt:**
> Run `composer install` (install any missing PHP extensions with `airlock-install`), then
> `composer test`. Then add `DELETE /notes/{id}` (204, or 404 if missing; invalidate the
> cache), with a test. Commit.

**Pass criteria:**
- `php -v` and `composer -V` work.
- The agent installs `php-pgsql`.
- After you allow the GitHub host, the packages install and the tests pass.
