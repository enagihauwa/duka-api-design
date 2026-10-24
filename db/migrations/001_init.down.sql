-- Duka Marketplace :: 001_init (down). Drops everything the up migration created.
BEGIN;
DROP FUNCTION IF EXISTS anonymise_user(uuid);
DROP TABLE IF EXISTS idempotency_keys, reviews, payment_events, payments, order_items,
                     order_events, orders, listings, categories, sellers, addresses, users,
                     state_transitions CASCADE;
DROP FUNCTION IF EXISTS reviews_aggregate(), reviews_before_update(), orders_after_change(),
  orders_before_update(), orders_before_insert(), payments_guard(), order_items_after_insert(),
  order_items_guard(), forbid_mutation(), listings_guard(), enforce_initial_status(),
  assert_transition(text, text, text), set_updated_at();
DROP TYPE IF EXISTS actor_kind, payment_status, order_status, listing_status, seller_status;
COMMIT;
