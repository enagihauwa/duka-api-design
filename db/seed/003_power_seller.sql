-- One high-volume seller (60k completed historical orders) to test whether the
-- fulfilment-queue partial index earns its keep as a seller's history grows.
-- Same loading approach as 002: business triggers off, CHECK/FK constraints on.
\set ON_ERROR_STOP on
BEGIN;
ALTER TABLE orders      DISABLE TRIGGER USER;
ALTER TABLE order_items DISABLE TRIGGER USER;

SELECT seller_id AS power_seller FROM orders WHERE status = 'paid'
 GROUP BY seller_id ORDER BY count(*) DESC, seller_id LIMIT 1 \gset

CREATE TEMP TABLE pl AS
  SELECT id, title, price_minor, row_number() OVER (ORDER BY id) AS rn
    FROM listings WHERE seller_id = :'power_seller' AND status = 'active' AND deleted_at IS NULL;
CREATE TEMP TABLE pa AS
  SELECT a.id AS address_id, a.user_id, row_number() OVER (ORDER BY a.id) AS rn
    FROM addresses a WHERE a.recipient_name LIKE 'Buyer %';
CREATE TEMP TABLE pstg AS
SELECT uuidv7() AS order_id, m, pa.user_id AS buyer_id, pa.address_id, pl.id AS listing_id, pl.title, pl.price_minor,
       now() - ((m % 700) + 25) * interval '1 day' - (m % 1440) * interval '1 minute' AS created_at
  FROM generate_series(1, 60000) m
  JOIN pa ON pa.rn = 1 + (m::bigint * 104729) % (SELECT count(*) FROM pa)
  JOIN pl ON pl.rn = 1 + (m::bigint * 7727)   % (SELECT count(*) FROM pl);

INSERT INTO orders (id, buyer_id, seller_id, status, currency, items_subtotal_minor, shipping_fee_minor,
                    shipping_address_id, seller_shop_name_snapshot, ship_recipient, ship_line1, ship_city,
                    ship_postal_code, ship_country, carrier, tracking_number,
                    paid_at, shipped_at, delivered_at, completed_at, created_at, updated_at)
SELECT p.order_id, p.buyer_id, :'power_seller', 'completed', 'NGN', p.price_minor, 100000, p.address_id,
       s.shop_name, 'Buyer', 'Market Street', 'Lagos', '100001', 'NG', 'GIGL', 'TRKP' || p.m,
       p.created_at + interval '1 hour', p.created_at + interval '1 day', p.created_at + interval '4 days',
       p.created_at + interval '6 days', p.created_at, p.created_at + interval '7 days'
  FROM pstg p, sellers s WHERE s.id = :'power_seller';
INSERT INTO order_items (order_id, listing_id, seller_id, currency, quantity, unit_price_minor, title_snapshot, created_at, updated_at)
SELECT order_id, listing_id, :'power_seller', 'NGN', 1, price_minor, title, created_at, created_at FROM pstg;

ALTER TABLE orders      ENABLE TRIGGER USER;
ALTER TABLE order_items ENABLE TRIGGER USER;
COMMIT;
ANALYZE orders; ANALYZE order_items;
SELECT count(*) AS power_seller_orders FROM orders WHERE seller_id = :'power_seller';
