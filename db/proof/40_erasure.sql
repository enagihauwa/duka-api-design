-- Compliance proof: soft delete + anonymisation keeps the financial record, destroys the person.
\set ECHO queries
\set VERBOSITY verbose
\set ON_ERROR_STOP off
\pset footer off

\echo
\echo '=== Refused: Bola has an open order (paid, not yet shipped)'
BEGIN;
SELECT anonymise_user('0190a000-0000-7000-8000-000000000003');
ROLLBACK;

\echo
\echo '=== Allowed: Efe has no open orders. Give Efe a completed order first, then erase.'
BEGIN;
SELECT set_config('app.actor_type', 'system', true) AS _a \gset
INSERT INTO orders (id, buyer_id, seller_id, currency, shipping_fee_minor, shipping_address_id)
VALUES ('0190a000-0000-7000-8005-0000000000e1', '0190a000-0000-7000-8000-000000000005',
        '0190a000-0000-7000-8001-000000000001', 'NGN', 150000, '0190a000-0000-7000-8002-000000000005');
INSERT INTO order_items (order_id, listing_id, quantity)
VALUES ('0190a000-0000-7000-8005-0000000000e1', '0190a000-0000-7000-8004-000000000002', 1);
INSERT INTO payments (id, order_id, currency, amount_minor, provider)
VALUES ('0190a000-0000-7000-8006-0000000000e1', '0190a000-0000-7000-8005-0000000000e1', 'NGN', 1950000, 'paystack');
UPDATE payments SET status = 'captured' WHERE id = '0190a000-0000-7000-8006-0000000000e1';
UPDATE orders SET status = 'paid' WHERE id = '0190a000-0000-7000-8005-0000000000e1';
UPDATE orders SET status = 'shipped', carrier = 'GIGL', tracking_number = 'E1' WHERE id = '0190a000-0000-7000-8005-0000000000e1';
UPDATE orders SET status = 'delivered' WHERE id = '0190a000-0000-7000-8005-0000000000e1';
UPDATE orders SET status = 'completed' WHERE id = '0190a000-0000-7000-8005-0000000000e1';

\echo '--- before'
SELECT u.email, u.full_name, o.order_number, o.total_minor, o.ship_recipient, o.ship_line1
  FROM users u JOIN orders o ON o.buyer_id = u.id WHERE u.id = '0190a000-0000-7000-8000-000000000005';
SELECT anonymise_user('0190a000-0000-7000-8000-000000000005');
\echo '--- after: person gone, money and order history intact'
SELECT u.email, u.full_name, u.deleted_at IS NOT NULL AS soft_deleted, o.order_number, o.total_minor, o.ship_recipient, o.ship_line1,
       (SELECT status FROM payments p WHERE p.order_id = o.id) AS payment_status
  FROM users u JOIN orders o ON o.buyer_id = u.id WHERE u.id = '0190a000-0000-7000-8000-000000000005';
\echo '--- and the erased order is still read-only'
UPDATE orders SET tracking_number = 'tamper' WHERE id = '0190a000-0000-7000-8005-0000000000e1';
ROLLBACK;
