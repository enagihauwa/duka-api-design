-- Invalid states the database must refuse. Every attempt runs in its own transaction
-- and is rolled back. VERBOSITY=verbose prints the SQLSTATE and the constraint name.
\set ECHO queries
\set VERBOSITY verbose
\set ON_ERROR_STOP off
\pset footer off

\echo
\echo '################ REQUIRED 1: oversell. Bluetooth speaker has stock 0; order one anyway ################'
SELECT title, stock_quantity FROM listings WHERE id = '0190a000-0000-7000-8004-000000000005';
BEGIN;
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id)
VALUES ('0190a000-0000-7000-8005-0000000000a1', '0190a000-0000-7000-8000-000000000003',
        '0190a000-0000-7000-8001-000000000002', 'NGN', 0, '0190a000-0000-7000-8002-000000000003');
INSERT INTO order_items (order_id, listing_id, quantity)
VALUES ('0190a000-0000-7000-8005-0000000000a1', '0190a000-0000-7000-8004-000000000005', 1);
ROLLBACK;

\echo
\echo '################ REQUIRED 2: a review for an order that is not completed (order is only paid) ################'
BEGIN;
INSERT INTO reviews (order_id, order_item_id, listing_id, buyer_id, rating, body)
SELECT oi.order_id, oi.id, oi.listing_id, '0190a000-0000-7000-8000-000000000003', 4, 'too early'
  FROM order_items oi
 WHERE oi.order_id = '0190a000-0000-7000-8005-000000000003'
   AND oi.listing_id = '0190a000-0000-7000-8004-000000000003';
ROLLBACK;

\echo
\echo '################ REQUIRED 3: forbidden state transition. completed -> shipped ################'
SELECT order_number, status FROM orders WHERE id = '0190a000-0000-7000-8005-000000000001';
BEGIN;
UPDATE orders SET status = 'shipped', carrier = 'GIGL', tracking_number = 'X'
 WHERE id = '0190a000-0000-7000-8005-000000000001';
ROLLBACK;

\echo
\echo '################ EXTRA 4: late payment webhook cannot resurrect a cancelled order (cancelled -> paid) ################'
BEGIN;
UPDATE orders SET status = 'paid' WHERE id = '0190a000-0000-7000-8005-000000000004';
ROLLBACK;

\echo
\echo '################ EXTRA 5: a shipped order cannot be cancelled (goods are in transit) ################'
BEGIN;
UPDATE orders SET status = 'cancelled', cancelled_by = 'seller'
 WHERE id = (SELECT id FROM orders WHERE status = 'shipped' LIMIT 1);
ROLLBACK;

\echo
\echo '################ EXTRA 6: an order cannot be marked paid without a captured payment ################'
BEGIN;
UPDATE orders SET status = 'paid' WHERE id = '0190a000-0000-7000-8005-000000000002';
ROLLBACK;

\echo
\echo '################ EXTRA 7: two live payments for one order ################'
BEGIN;
INSERT INTO payments (order_id, currency, amount_minor, provider)
VALUES ('0190a000-0000-7000-8005-000000000002', 'NGN', 3000000, 'paystack');
INSERT INTO payments (order_id, currency, amount_minor, provider)
VALUES ('0190a000-0000-7000-8005-000000000002', 'NGN', 3000000, 'paystack');
ROLLBACK;

\echo
\echo '################ EXTRA 8: a payment whose amount is not the order total ################'
BEGIN;
INSERT INTO payments (order_id, currency, amount_minor, provider)
VALUES ('0190a000-0000-7000-8005-000000000002', 'NGN', 1, 'paystack');
ROLLBACK;

\echo
\echo '################ EXTRA 9: an order mixing two sellers (item from Kente Cloth Co in a Lagos Gadgets order) ################'
BEGIN;
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id)
VALUES ('0190a000-0000-7000-8005-0000000000a9', '0190a000-0000-7000-8000-000000000003',
        '0190a000-0000-7000-8001-000000000002', 'NGN', 0, '0190a000-0000-7000-8002-000000000003');
INSERT INTO order_items (order_id, listing_id, quantity)
VALUES ('0190a000-0000-7000-8005-0000000000a9', '0190a000-0000-7000-8004-000000000001', 1);
ROLLBACK;

\echo
\echo '################ EXTRA 10: a seller buying from their own shop ################'
BEGIN;
INSERT INTO addresses (id, user_id, recipient_name, line1, city, postal_code, country)
VALUES ('0190a000-0000-7000-8002-0000000000aa', '0190a000-0000-7000-8000-000000000001', 'Amina', '1 Test St', 'Lagos', '100001', 'NG');
INSERT INTO orders (buyer_id, seller_id, currency, shipping_address_id)
VALUES ('0190a000-0000-7000-8000-000000000001', '0190a000-0000-7000-8001-000000000001', 'NGN', '0190a000-0000-7000-8002-0000000000aa');
ROLLBACK;

\echo
\echo '################ EXTRA 11: shipping to someone else''s address ################'
BEGIN;
INSERT INTO orders (buyer_id, seller_id, currency, shipping_address_id)
VALUES ('0190a000-0000-7000-8000-000000000003', '0190a000-0000-7000-8001-000000000002', 'NGN',
        '0190a000-0000-7000-8002-000000000004');
ROLLBACK;

\echo
\echo '################ EXTRA 12: money must be positive whole minor units with an ISO currency ################'
BEGIN;
INSERT INTO listings (seller_id, category_id, title, price_minor, currency, stock_quantity)
VALUES ('0190a000-0000-7000-8001-000000000001', '0190a000-0000-7000-8003-000000000002', 'Free cloth', 0, 'NGN', 1);
ROLLBACK;
BEGIN;
INSERT INTO listings (seller_id, category_id, title, price_minor, currency, stock_quantity)
VALUES ('0190a000-0000-7000-8001-000000000001', '0190a000-0000-7000-8003-000000000002', 'Wrong currency', 1000, 'USD', 1);
ROLLBACK;

\echo
\echo '################ EXTRA 13: an order cannot be born already completed ################'
BEGIN;
INSERT INTO orders (buyer_id, seller_id, status, currency, shipping_address_id)
VALUES ('0190a000-0000-7000-8000-000000000003', '0190a000-0000-7000-8001-000000000002', 'completed', 'NGN',
        '0190a000-0000-7000-8002-000000000003');
ROLLBACK;

\echo
\echo '################ EXTRA 14: the price on a finished order line is immutable ################'
BEGIN;
UPDATE order_items SET unit_price_minor = 1 WHERE order_id = '0190a000-0000-7000-8005-000000000001';
ROLLBACK;

\echo
\echo '################ EXTRA 15: the audit trail is append-only ################'
BEGIN;
DELETE FROM order_events WHERE order_id = '0190a000-0000-7000-8005-000000000001';
ROLLBACK;

\echo
\echo '################ EXTRA 16: a second review for the same line ################'
BEGIN;
INSERT INTO reviews (order_id, order_item_id, listing_id, buyer_id, rating)
SELECT oi.order_id, oi.id, oi.listing_id, '0190a000-0000-7000-8000-000000000003', 1
  FROM order_items oi
 WHERE oi.order_id = '0190a000-0000-7000-8005-000000000001'
   AND oi.listing_id = '0190a000-0000-7000-8004-000000000001';
ROLLBACK;
