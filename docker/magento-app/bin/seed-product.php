<?php
/**
 * Creates ONE simple, visible, in-stock demo product so the storefront has at
 * least one openable product. Runs offline via Magento's
 * bootstrap - no web server required - so it is safe inside the install Job.
 */
require '/var/www/html/app/bootstrap.php';

use Magento\Framework\App\Bootstrap;

$bootstrap = Bootstrap::create(BP, $_SERVER);
$om = $bootstrap->getObjectManager();
$om->get(\Magento\Framework\App\State::class)->setAreaCode('adminhtml');

$sku = 'demo-product-1';
$productRepository = $om->get(\Magento\Catalog\Api\ProductRepositoryInterface::class);

try {
    $productRepository->get($sku);
    echo "Demo product already exists, skipping.\n";
    exit(0);
} catch (\Magento\Framework\Exception\NoSuchEntityException $e) {
    // not found -> create it
}

/** @var \Magento\Catalog\Api\Data\ProductInterface $product */
$product = $om->create(\Magento\Catalog\Api\Data\ProductInterface::class);
$product->setSku($sku)
    ->setName('Demo Product')
    ->setAttributeSetId(4)                 // default attribute set
    ->setStatus(\Magento\Catalog\Model\Product\Attribute\Source\Status::STATUS_ENABLED)
    ->setVisibility(\Magento\Catalog\Model\Product\Visibility::VISIBILITY_BOTH)
    ->setTypeId(\Magento\Catalog\Model\Product\Type::TYPE_SIMPLE)
    ->setPrice(19.99)
    ->setWebsiteIds([1])
    ->setStockData(['use_config_manage_stock' => 1, 'qty' => 100, 'is_in_stock' => 1]);

$productRepository->save($product);

// Attach to the default category so it is browsable from the storefront.
$om->get(\Magento\Catalog\Api\CategoryLinkManagementInterface::class)
   ->assignProductToCategories($sku, [2]);

echo "Demo product '{$sku}' created.\n";
