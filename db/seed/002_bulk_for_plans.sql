-- Bulk data so the planner has a reason to prefer indexes (on 5 rows it never would).
-- Loads ~20k users, 1k sellers, 200k listings, 300k orders, ~300k items/payments, reviews.
-- Only the *business* triggers are switched off while loading (they would otherwise
-- walk 300k orders through every status). CHECK and FOREIGN KEY constraints stay ON;
-- the audit at the bottom proves the denormalised totals still agree.
\set ON_ERROR_STOP on
\timing on
BEGIN;
SELECT setseed(0.42);

ALTER TABLE listings    DISABLE TRIGGER USER;
ALTER TABLE orders      DISABLE TRIGGER USER;
ALTER TABLE order_items DISABLE TRIGGER USER;
ALTER TABLE payments    DISABLE TRIGGER USER;
ALTER TABLE reviews     DISABLE TRIGGER USER;

-- users -------------------------------------------------------------
INSERT INTO users (email, full_name, phone_e164, created_at, updated_at)
SELECT 'bulk' || n || '@example.com', 'Bulk User ' || n, '+2348100' || lpad(n::text, 7, '0'), ts, ts
  FROM (SELECT n, now() - (n % 700 + 30) * interval '1 day' AS ts FROM generate_series(1, 20000) n) g;
CREATE TEMP TABLE bu AS
  SELECT id, row_number() OVER (ORDER BY email) AS rn FROM users WHERE email LIKE 'bulk%@example.com';
-- NB: ORDER BY email is lexicographic; rn is just a stable arbitrary numbering.

-- sellers = first 1000 bulk users; everybody else is a buyer ----------
INSERT INTO sellers (user_id, shop_name, shop_slug, currency, status, created_at, updated_at)
SELECT id, 'Shop ' || rn, 'shop-' || rn, 'NGN', 'active', now() - interval '800 days', now() - interval '800 days'
  FROM bu WHERE rn <= 1000;
CREATE TEMP TABLE bs AS
  SELECT s.id, s.shop_name, row_number() OVER (ORDER BY s.shop_slug) AS rn
    FROM sellers s JOIN bu ON bu.id = s.user_id;

INSERT INTO categories (name, slug)
SELECT 'Category ' || n, 'cat-' || n FROM generate_series(1, 40) n;
CREATE TEMP TABLE bc AS
  SELECT id, row_number() OVER (ORDER BY slug) AS rn FROM categories WHERE slug LIKE 'cat-%';

-- listings ----------------------------------------------------------
INSERT INTO listings (seller_id, category_id, title, description, price_minor, currency,
                      stock_quantity, status, created_at, updated_at, deleted_at)
SELECT s.id, c.id,
       (ARRAY['Handmade','Vintage','Premium','Refurbished','Organic','Classic','Compact','Deluxe','Eco','Artisan','Imported','Local'])[1 + n % 12] || ' ' ||
       (ARRAY['cloth','speaker','phone','lamp','bag','shoes','table','chair','watch','soap','basket','drum','mirror','jacket','blender','headset','mat','vase','kettle','necklace'])[1 + (n / 12) % 20] || ' ' || n,
       'Description for item ' || n || ' with some searchable words like quality warranty fast delivery',
       50000 + (n::bigint * 7919) % 5000000, 'NGN', n % 50,
       CASE WHEN n % 25 = 0 THEN 'draft' WHEN n % 10 = 0 THEN 'paused' ELSE 'active' END::listing_status,
       ts, ts, CASE WHEN n % 97 = 0 THEN ts + interval '1 day' END
  FROM (SELECT n, now() - (n % 600 + 5) * interval '1 day' - (n % 1440) * interval '1 minute' AS ts
          FROM generate_series(1, 200000) n) g
  JOIN bs s ON s.rn = 1 + (g.n::bigint * 7919) % 1000
  JOIN bc c ON c.rn = 1 + (g.n::bigint * 104729) % 40;

-- buyers' default addresses ---------------------------------------------
INSERT INTO addresses (user_id, recipient_name, line1, city, postal_code, country, is_default, created_at, updated_at)
SELECT id, 'Buyer ' || rn, rn || ' Market Street', 'Lagos', '100001', 'NG', true, now() - interval '400 days', now() - interval '400 days'
  FROM bu WHERE rn > 1000;
CREATE TEMP TABLE ba AS
  SELECT a.id AS address_id, a.user_id, row_number() OVER (ORDER BY a.user_id) AS rn
    FROM addresses a JOIN bu ON bu.id = a.user_id WHERE bu.rn > 1000;

-- order staging: 300k single-line orders -----------------------------
CREATE TEMP TABLE bl AS
  SELECT l.id, l.seller_id, l.title, l.price_minor, row_number() OVER (ORDER BY l.id) AS rn
    FROM listings l WHERE l.status = 'active' AND l.deleted_at IS NULL
     AND l.seller_id IN (SELECT id FROM bs);   -- bulk sellers only
CREATE TEMP TABLE stg AS
SELECT uuidv7() AS order_id, m,
       ba.user_id AS buyer_id, ba.address_id, bl.id AS listing_id, bl.seller_id, bl.title, bl.price_minor,
       1 + m % 3 AS qty, 100000 + (m % 5) * 50000 AS ship_fee,
       (ARRAY['completed','completed','completed','completed','completed','completed','completed','completed','completed','completed','completed','completed',
              'paid','shipped','delivered','cancelled','cancelled','pending_payment','pending_payment','refunded'])[1 + m % 20]::order_status AS status,
       now() - ((m % 365) + 25) * interval '1 day' - (m % 1440) * interval '1 minute' AS created_at
  FROM generate_series(1, 300000) m
  JOIN ba ON ba.rn = 1 + (m::bigint * 104729) % (SELECT count(*) FROM ba)
  JOIN bl ON bl.rn = 1 + (m::bigint * 7727)   % (SELECT count(*) FROM bl);

INSERT INTO orders (id, buyer_id, seller_id, status, currency, items_subtotal_minor, shipping_fee_minor,
                    shipping_address_id, seller_shop_name_snapshot, ship_recipient, ship_line1, ship_city,
                    ship_postal_code, ship_country, carrier, tracking_number,
                    paid_at, shipped_at, delivered_at, completed_at, cancelled_at, cancelled_by,
                    created_at, updated_at)
SELECT s.order_id, s.buyer_id, s.seller_id, s.status, 'NGN', s.qty * s.price_minor, s.ship_fee,
       s.address_id, bs.shop_name, 'Buyer', 'Market Street', 'Lagos', '100001', 'NG',
       CASE WHEN s.status IN ('shipped','delivered','completed','refunded') THEN 'GIGL' END,
       CASE WHEN s.status IN ('shipped','delivered','completed','refunded') THEN 'TRK' || s.m END,
       CASE WHEN s.status IN ('paid','shipped','delivered','completed','refunded') THEN s.created_at + interval '1 hour' END,
       CASE WHEN s.status IN ('shipped','delivered','completed','refunded') THEN s.created_at + interval '1 day' END,
       CASE WHEN s.status IN ('delivered','completed','refunded') THEN s.created_at + interval '4 days' END,
       CASE WHEN s.status = 'completed' THEN s.created_at + interval '6 days' END,
       CASE WHEN s.status = 'cancelled' THEN s.created_at + interval '2 hours' END,
       CASE WHEN s.status = 'cancelled' THEN 'buyer'::actor_kind END,
       s.created_at, s.created_at + interval '7 days'
  FROM stg s JOIN bs ON bs.id = s.seller_id;

INSERT INTO order_items (order_id, listing_id, seller_id, currency, quantity, unit_price_minor, title_snapshot, created_at, updated_at)
SELECT order_id, listing_id, seller_id, 'NGN', qty, price_minor, title, created_at, created_at FROM stg;

INSERT INTO payments (order_id, currency, amount_minor, status, provider, provider_reference, captured_at, created_at, updated_at)
SELECT o.id, 'NGN', o.total_minor,
       CASE WHEN o.status = 'refunded' THEN 'refunded' ELSE 'captured' END::payment_status,
       'paystack', 'BULK_' || o.order_number, o.paid_at, o.created_at, o.created_at + interval '1 hour'
  FROM orders o
 WHERE o.status IN ('paid','shipped','delivered','completed','refunded')
   AND o.order_number IS NOT NULL AND o.id IN (SELECT order_id FROM stg);

INSERT INTO reviews (order_id, order_item_id, listing_id, buyer_id, rating, body, created_at, updated_at)
SELECT oi.order_id, oi.id, oi.listing_id, o.buyer_id, 1 + (abs(hashtext(o.id::text)) % 5), 'Bulk review',
       o.completed_at + interval '1 day', o.completed_at + interval '1 day'
  FROM orders o JOIN order_items oi ON oi.order_id = o.id
 WHERE o.status = 'completed' AND abs(hashtext(o.id::text)) % 5 < 2
   AND o.id IN (SELECT order_id FROM stg);

-- rebuild the cached rating aggregates from the reviews
UPDATE listings l SET rating_sum = r.s, rating_count = r.c
  FROM (SELECT listing_id, sum(rating) s, count(*) c FROM reviews WHERE deleted_at IS NULL GROUP BY listing_id) r
 WHERE r.listing_id = l.id;

ALTER TABLE listings    ENABLE TRIGGER USER;
ALTER TABLE orders      ENABLE TRIGGER USER;
ALTER TABLE order_items ENABLE TRIGGER USER;
ALTER TABLE payments    ENABLE TRIGGER USER;
ALTER TABLE reviews     ENABLE TRIGGER USER;
COMMIT;

ANALYZE;

-- audit: every denormalised fact must still agree with its source
\echo '--- audit: orders whose subtotal != sum(items)  (expect 0)'
SELECT count(*) FROM orders o
 WHERE o.items_subtotal_minor <> (SELECT sum(line_total_minor) FROM order_items WHERE order_id = o.id);
\echo '--- audit: listings whose rating cache != live reviews  (expect 0)'
SELECT count(*) FROM listings l
 WHERE (l.rating_sum, l.rating_count) <> (SELECT coalesce(sum(rating),0), count(*) FROM reviews WHERE listing_id = l.id AND deleted_at IS NULL);
\echo '--- row counts'
SELECT 'users' t, count(*) FROM users UNION ALL SELECT 'listings', count(*) FROM listings
UNION ALL SELECT 'orders', count(*) FROM orders UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'payments', count(*) FROM payments UNION ALL SELECT 'reviews', count(*) FROM reviews;
