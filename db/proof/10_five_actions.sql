-- The five important actions, as the SQL the API would run for each.
-- Mutating actions run inside a transaction that is rolled back so the proof is repeatable.
\set ECHO queries
\pset footer off
\set s_kente '0190a000-0000-7000-8001-000000000001'
\set s_gadget '0190a000-0000-7000-8001-000000000002'
\set u_bola  '0190a000-0000-7000-8000-000000000003'
\set a_bola  '0190a000-0000-7000-8002-000000000003'

\echo
\echo '=== Q1  Seller publishes a listing (draft -> active)  [A1]'
BEGIN;
SELECT set_config('app.actor_type', 'seller', true) AS _a \gset
INSERT INTO listings (id, seller_id, category_id, title, description, price_minor, currency, stock_quantity)
VALUES ('0190a000-0000-7000-8004-0000000000f1', :'s_kente', '0190a000-0000-7000-8003-000000000002',
        'Adire indigo fabric', 'Hand dyed in Abeokuta', 2200000, 'NGN', 12);
UPDATE listings SET status = 'active' WHERE id = '0190a000-0000-7000-8004-0000000000f1'
RETURNING id, title, price_minor, currency, stock_quantity, status;
ROLLBACK;

\echo
\echo '=== Q2  Buyer searches listings: keyword + price filter, ranked, page 1  [A2]'
SELECT l.id, l.title, l.price_minor, l.currency, l.rating_sum, l.rating_count,
       ts_rank(l.search_tsv, q) AS rank
  FROM listings l, websearch_to_tsquery('simple', 'premium lamp') q
 WHERE l.status = 'active' AND l.deleted_at IS NULL
   AND l.search_tsv @@ q
   AND l.price_minor BETWEEN 100000 AND 3000000
 ORDER BY rank DESC, l.id DESC
 LIMIT 5;

\echo
\echo '=== Q3  Buyer places an order: order + item; price snapshotted, stock reserved, subtotal maintained  [A3]'
BEGIN;
SELECT set_config('app.actor_type', 'buyer', true) AS _a \gset
SELECT stock_quantity AS stock_before FROM listings WHERE id = '0190a000-0000-7000-8004-000000000004';
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id)
VALUES ('0190a000-0000-7000-8005-0000000000f3', :'u_bola', :'s_gadget', 'NGN', 200000, :'a_bola');
INSERT INTO order_items (order_id, listing_id, quantity)
VALUES ('0190a000-0000-7000-8005-0000000000f3', '0190a000-0000-7000-8004-000000000004', 2);
SELECT o.order_number, o.status, o.items_subtotal_minor, o.shipping_fee_minor, o.total_minor, o.currency,
       o.seller_shop_name_snapshot, o.ship_recipient, o.ship_city,
       (SELECT stock_quantity FROM listings WHERE id = '0190a000-0000-7000-8004-000000000004') AS stock_after
  FROM orders o WHERE o.id = '0190a000-0000-7000-8005-0000000000f3';
SELECT title_snapshot, quantity, unit_price_minor, line_total_minor
  FROM order_items WHERE order_id = '0190a000-0000-7000-8005-0000000000f3';
ROLLBACK;

\echo
\echo '=== Q4  Buyer pays: payment pending -> authorized -> captured, then order pending_payment -> paid  [A4]'
BEGIN;
SELECT set_config('app.actor_type', 'system', true) AS _a \gset
INSERT INTO payments (id, order_id, currency, amount_minor, provider)
VALUES ('0190a000-0000-7000-8006-0000000000f4', '0190a000-0000-7000-8005-000000000002', 'NGN', 3000000, 'paystack');
UPDATE payments SET status = 'authorized', provider_reference = 'PSK_F4' WHERE id = '0190a000-0000-7000-8006-0000000000f4';
UPDATE payments SET status = 'captured' WHERE id = '0190a000-0000-7000-8006-0000000000f4';
UPDATE orders SET status = 'paid' WHERE id = '0190a000-0000-7000-8005-000000000002'
RETURNING order_number, status, total_minor, paid_at IS NOT NULL AS has_paid_at;
SELECT from_status, to_status, actor_type FROM order_events
 WHERE order_id = '0190a000-0000-7000-8005-000000000002' ORDER BY created_at, id;
ROLLBACK;

\echo
\echo '=== Q5  Seller works the fulfilment queue, then ships the oldest paid order  [A5]'
SELECT o.id, o.order_number, o.created_at::date AS ordered, o.total_minor, o.currency, o.ship_city,
       (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS lines
  FROM orders o
 WHERE o.seller_id = :'s_gadget' AND o.status = 'paid'
 ORDER BY o.created_at, o.id
 LIMIT 20;
BEGIN;
SELECT set_config('app.actor_type', 'seller', true) AS _a \gset
UPDATE orders SET status = 'shipped', carrier = 'GIGL', tracking_number = 'GIG999'
 WHERE id = '0190a000-0000-7000-8005-000000000003' AND seller_id = :'s_gadget' AND status = 'paid'
RETURNING order_number, status, carrier, tracking_number, shipped_at IS NOT NULL AS has_shipped_at;
ROLLBACK;
