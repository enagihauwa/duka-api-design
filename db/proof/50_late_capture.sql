-- The non-obvious forbidden transition: cancelled -> paid.
-- Scenario: buyer starts paying, the 30-minute expiry job cancels the order, THEN the
-- provider's capture webhook arrives. The money moved; the order must not come back to life.
\set ECHO queries
\set VERBOSITY verbose
\set ON_ERROR_STOP off
\pset footer off
BEGIN;
SELECT set_config('app.actor_type', 'system', true) AS _a \gset
INSERT INTO payments (id, order_id, currency, amount_minor, provider, provider_reference)
VALUES ('0190a000-0000-7000-8006-0000000000b1', '0190a000-0000-7000-8005-000000000002', 'NGN', 3000000, 'paystack', 'PSK_LATE');
UPDATE payments SET status = 'authorized' WHERE id = '0190a000-0000-7000-8006-0000000000b1';
\echo '--- expiry job cancels the unpaid order (stock is released)'
UPDATE orders SET status = 'cancelled', cancelled_by = 'system' WHERE id = '0190a000-0000-7000-8005-000000000002';
\echo '--- late webhook: provider says captured. The payment row records the truth'
UPDATE payments SET status = 'captured' WHERE id = '0190a000-0000-7000-8006-0000000000b1';
\echo '--- ...but the order cannot be resurrected'
SAVEPOINT s;
UPDATE orders SET status = 'paid' WHERE id = '0190a000-0000-7000-8005-000000000002';
ROLLBACK TO SAVEPOINT s;
\echo '--- reconciliation query: cancelled orders that hold captured money -> refund queue'
SELECT o.order_number, o.status AS order_status, p.status AS payment_status, p.amount_minor, p.currency
  FROM orders o JOIN payments p ON p.order_id = o.id
 WHERE o.status = 'cancelled' AND p.status = 'captured';
ROLLBACK;
