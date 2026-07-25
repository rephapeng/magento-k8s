<?php
/**
 * Build-time helper: add / remove the store scopes in app/etc/config.php.
 *
 * `setup:static-content:deploy` has to know which store views to deploy for.
 * On an installed instance it reads them from the database; during a DB-less
 * build (Magento's "pipeline deployment" build phase) it reads the `scopes`
 * section of app/etc/config.php, which is normally produced by running
 * `bin/magento app:config:dump` on a live instance. A fresh
 * `composer create-project` has neither, so the command aborts with
 * "The default website isn't defined."
 *
 * This writes exactly the scopes a stock `setup:install` creates, so static
 * content is generated for the same store view the installer will later make.
 *
 * The scopes are removed again right after the deploy: shipping them in the
 * image would make website/store configuration read-only ("locked by
 * config.php") in the Admin UI, and the install Job writes the real values to
 * the database anyway.
 *
 * Usage:  php build-scopes.php add|remove
 */

$mode = $argv[1] ?? '';
if (!in_array($mode, ['add', 'remove'], true)) {
    fwrite(STDERR, "usage: build-scopes.php add|remove\n");
    exit(1);
}

$file = getenv('MAGENTO_CONFIG_PHP') ?: '/var/www/html/app/etc/config.php';
if (!is_file($file)) {
    fwrite(STDERR, "ERROR: $file not found (run module:enable first)\n");
    exit(1);
}

$config = require $file;
if (!is_array($config)) {
    fwrite(STDERR, "ERROR: $file did not return an array\n");
    exit(1);
}

if ($mode === 'add') {
    // Mirrors the rows setup:install inserts into store_website / store_group /
    // store for a default Magento Open Source installation.
    $config['scopes'] = [
        'websites' => [
            'admin' => [
                'website_id' => '0', 'code' => 'admin', 'name' => 'Admin',
                'sort_order' => '0', 'default_group_id' => '0', 'is_default' => '0',
            ],
            'base' => [
                'website_id' => '1', 'code' => 'base', 'name' => 'Main Website',
                'sort_order' => '0', 'default_group_id' => '1', 'is_default' => '1',
            ],
        ],
        'groups' => [
            0 => [
                'group_id' => '0', 'website_id' => '0', 'code' => 'default',
                'name' => 'Default', 'root_category_id' => '0', 'default_store_id' => '0',
            ],
            1 => [
                'group_id' => '1', 'website_id' => '1', 'code' => 'main_website_store',
                'name' => 'Main Website Store', 'root_category_id' => '2', 'default_store_id' => '1',
            ],
        ],
        'stores' => [
            'admin' => [
                'store_id' => '0', 'code' => 'admin', 'website_id' => '0', 'group_id' => '0',
                'name' => 'Admin', 'sort_order' => '0', 'is_active' => '1',
            ],
            'default' => [
                'store_id' => '1', 'code' => 'default', 'website_id' => '1', 'group_id' => '1',
                'name' => 'Default Store View', 'sort_order' => '0', 'is_active' => '1',
            ],
        ],
    ];
} else {
    unset($config['scopes']);
}

file_put_contents($file, "<?php\nreturn " . var_export($config, true) . ";\n");
echo "config.php scopes: {$mode}d\n";
