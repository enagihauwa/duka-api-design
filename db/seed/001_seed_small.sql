-- Small, hand-readable dataset. Orders are walked through their lifecycle with
-- real UPDATEs, so the transition triggers are exercised by the seed itself.
BEGIN;

INSERT INTO users (id, email, full_name, phone_e164) VALUES
 ('0190a000-0000-7000-8000-000000000001', 'amina@kente.example',   'Amina Bello',  '+2348030000001'),
 ('0190a000-0000-7000-8000-000000000002', 'chidi@gadgets.example', 'Chidi Okafor', '+2348030000002'),
 ('0190a000-0000-7000-8000-000000000003', 'bola@example.com',      'Bola Adeyemi', '+2348030000003'),
 ('0190a000-0000-7000-8000-000000000004', 'tunde@example.com',     'Tunde Bakare', '+2348030000004'),
 ('0190a000-0000-7000-8000-000000000005', 'efe@example.com',       'Efe Umeh',     '+2348030000005');

INSERT INTO sellers (id, user_id, shop_name, shop_slug, currency, flat_shipping_fee_minor, status) VALUES
 ('0190a000-0000-7000-8001-000000000001', '0190a000-0000-7000-8000-000000000001', 'Kente Cloth Co', 'kente-cloth-co', 'NGN', 150000, 'active'),
 ('0190a000-0000-7000-8001-000000000002', '0190a000-0000-7000-8000-000000000002', 'Lagos Gadgets',  'lagos-gadgets',  'NGN', 200000, 'active'),
 ('0190a000-0000-7000-8001-000000000003', '0190a000-0000-7000-8000-000000000004', 'Tunde Thrift',   'tunde-thrift',   'NGN', 100000, 'pending_review');

INSERT INTO addresses (id, user_id, recipient_name, line1, city, region, postal_code, country, phone_e164, is_default) VALUES
 ('0190a000-0000-7000-8002-000000000003', '0190a000-0000-7000-8000-000000000003', 'Bola Adeyemi', '12 Allen Avenue', 'Lagos',      'LA', '100001', 'NG', '+2348030000003', true),
 ('0190a000-0000-7000-8002-000000000004', '0190a000-0000-7000-8000-000000000004', 'Tunde Bakare', '4 Awolowo Road',  'Ibadan',     'OY', '200001', 'NG', '+2348030000004', true),
 ('0190a000-0000-7000-8002-000000000005', '0190a000-0000-7000-8000-000000000005', 'Efe Umeh',     '9 Ring Road',     'Benin City', 'ED', '300001', 'NG', NULL,             true);

INSERT INTO categories (id, parent_id, name, slug) VALUES
 ('0190a000-0000-7000-8003-000000000001', NULL, 'Fashion',     'fashion'),
 ('0190a000-0000-7000-8003-000000000002', '0190a000-0000-7000-8003-000000000001', 'Fabrics', 'fabrics'),
 ('0190a000-0000-7000-8003-000000000003', NULL, 'Electronics', 'electronics'),
 ('0190a000-0000-7000-8003-000000000004', '0190a000-0000-7000-8003-000000000003', 'Phones',  'phones');

-- listings are born as drafts, then published
INSERT INTO listings (id, seller_id, category_id, title, description, price_minor, currency, stock_quantity) VALUES
 ('0190a000-0000-7000-8004-000000000001', '0190a000-0000-7000-8001-000000000001', '0190a000-0000-7000-8003-000000000002', 'Handwoven Kente cloth, blue and gold', 'Six yards, hand loomed in Ghana', 4500000,  'NGN', 10),
 ('0190a000-0000-7000-8004-000000000002', '0190a000-0000-7000-8001-000000000001', '0190a000-0000-7000-8003-000000000002', 'Ankara wax print, 6 yards',            'Vibrant cotton wax print',       1800000,  'NGN', 25),
 ('0190a000-0000-7000-8004-000000000003', '0190a000-0000-7000-8001-000000000002', '0190a000-0000-7000-8003-000000000004', 'Refurbished smartphone 128GB',          'Grade A, 12 month warranty',     12500000, 'NGN', 3),
 ('0190a000-0000-7000-8004-000000000004', '0190a000-0000-7000-8001-000000000002', '0190a000-0000-7000-8003-000000000004', 'Phone case, shockproof',                'Fits most 6 inch phones',        350000,   'NGN', 100),
 ('0190a000-0000-7000-8004-000000000005', '0190a000-0000-7000-8001-000000000002', '0190a000-0000-7000-8003-000000000003', 'Bluetooth speaker',                     'Waterproof, 12 hour battery',    2800000,  'NGN', 1);
UPDATE listings SET status = 'active' WHERE id IN (
 '0190a000-0000-7000-8004-000000000001', '0190a000-0000-7000-8004-000000000002',
 '0190a000-0000-7000-8004-000000000003', '0190a000-0000-7000-8004-000000000004',
 '0190a000-0000-7000-8004-000000000005');

-- ===== O1: Bola buys from Kente Cloth Co. Full happy path, then reviewed.
SELECT set_config('app.actor_type', 'buyer', true), set_config('app.actor_id', '0190a000-0000-7000-8000-000000000003', true);
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id) VALUES
 ('0190a000-0000-7000-8005-000000000001', '0190a000-0000-7000-8000-000000000003', '0190a000-0000-7000-8001-000000000001', 'NGN', 150000, '0190a000-0000-7000-8002-000000000003');
INSERT INTO order_items (order_id, listing_id, quantity) VALUES
 ('0190a000-0000-7000-8005-000000000001', '0190a000-0000-7000-8004-000000000001', 1),
 ('0190a000-0000-7000-8005-000000000001', '0190a000-0000-7000-8004-000000000002', 2);
INSERT INTO payments (id, order_id, currency, amount_minor, provider) VALUES
 ('0190a000-0000-7000-8006-000000000001', '0190a000-0000-7000-8005-000000000001', 'NGN', 8250000, 'paystack');
SELECT set_config('app.actor_type', 'system', true);
UPDATE payments SET status = 'authorized', provider_reference = 'PSK_001' WHERE id = '0190a000-0000-7000-8006-000000000001';
UPDATE payments SET status = 'captured' WHERE id = '0190a000-0000-7000-8006-000000000001';
UPDATE orders   SET status = 'paid'     WHERE id = '0190a000-0000-7000-8005-000000000001';
SELECT set_config('app.actor_type', 'seller', true), set_config('app.actor_id', '0190a000-0000-7000-8000-000000000001', true);
UPDATE orders   SET status = 'shipped', carrier = 'GIGL', tracking_number = 'GIG123456' WHERE id = '0190a000-0000-7000-8005-000000000001';
SELECT set_config('app.actor_type', 'system', true);
UPDATE orders   SET status = 'delivered' WHERE id = '0190a000-0000-7000-8005-000000000001';
SELECT set_config('app.actor_type', 'buyer', true), set_config('app.actor_id', '0190a000-0000-7000-8000-000000000003', true);
UPDATE orders   SET status = 'completed' WHERE id = '0190a000-0000-7000-8005-000000000001';
INSERT INTO reviews (order_id, order_item_id, listing_id, buyer_id, rating, body)
SELECT oi.order_id, oi.id, oi.listing_id, '0190a000-0000-7000-8000-000000000003', 5, 'Beautiful cloth, arrived well packed.'
  FROM order_items oi
 WHERE oi.order_id = '0190a000-0000-7000-8005-000000000001'
   AND oi.listing_id = '0190a000-0000-7000-8004-000000000001';

-- ===== O2: Tunde has an unpaid order with Lagos Gadgets (pending_payment)
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id) VALUES
 ('0190a000-0000-7000-8005-000000000002', '0190a000-0000-7000-8000-000000000004', '0190a000-0000-7000-8001-000000000002', 'NGN', 200000, '0190a000-0000-7000-8002-000000000004');
INSERT INTO order_items (order_id, listing_id, quantity) VALUES
 ('0190a000-0000-7000-8005-000000000002', '0190a000-0000-7000-8004-000000000005', 1);

-- ===== O3: Bola has a paid order waiting to ship (the seller's fulfilment queue)
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id) VALUES
 ('0190a000-0000-7000-8005-000000000003', '0190a000-0000-7000-8000-000000000003', '0190a000-0000-7000-8001-000000000002', 'NGN', 200000, '0190a000-0000-7000-8002-000000000003');
INSERT INTO order_items (order_id, listing_id, quantity) VALUES
 ('0190a000-0000-7000-8005-000000000003', '0190a000-0000-7000-8004-000000000003', 1),
 ('0190a000-0000-7000-8005-000000000003', '0190a000-0000-7000-8004-000000000004', 2);
INSERT INTO payments (id, order_id, currency, amount_minor, provider, provider_reference) VALUES
 ('0190a000-0000-7000-8006-000000000003', '0190a000-0000-7000-8005-000000000003', 'NGN', 13400000, 'paystack', 'PSK_003');
UPDATE payments SET status = 'captured' WHERE id = '0190a000-0000-7000-8006-000000000003';
UPDATE orders   SET status = 'paid'     WHERE id = '0190a000-0000-7000-8005-000000000003';

-- ===== O4: Tunde cancels before paying; stock is returned by trigger
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id) VALUES
 ('0190a000-0000-7000-8005-000000000004', '0190a000-0000-7000-8000-000000000004', '0190a000-0000-7000-8001-000000000001', 'NGN', 150000, '0190a000-0000-7000-8002-000000000004');
INSERT INTO order_items (order_id, listing_id, quantity) VALUES
 ('0190a000-0000-7000-8005-000000000004', '0190a000-0000-7000-8004-000000000002', 5);
UPDATE orders SET status = 'cancelled', cancelled_by = 'buyer' WHERE id = '0190a000-0000-7000-8005-000000000004';

COMMIT;
