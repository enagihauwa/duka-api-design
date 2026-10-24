-- Query plans for the two heaviest queries (search, seller queue), plus the two
-- list endpoints that share the same index families (buyer history, category browse).
-- Run against the bulk dataset (200k listings / 300k orders).
\pset footer off
\set ECHO queries

-- pick realistic parameters from the data
SELECT seller_id AS busy_seller FROM orders WHERE status = 'paid' GROUP BY seller_id ORDER BY count(*) DESC, seller_id LIMIT 1 \gset
SELECT buyer_id  AS busy_buyer  FROM orders GROUP BY buyer_id ORDER BY count(*) DESC LIMIT 1 \gset
SELECT id AS some_cat FROM categories WHERE slug = 'cat-7' \gset

\echo
\echo '######## PLAN 1 (heaviest): keyword search + price filter, ranked ########'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT l.id, l.title, l.price_minor, l.currency, ts_rank(l.search_tsv, q) AS rank
  FROM listings l, websearch_to_tsquery('simple', 'premium lamp') q
 WHERE l.status = 'active' AND l.deleted_at IS NULL
   AND l.search_tsv @@ q
   AND l.price_minor BETWEEN 100000 AND 3000000
 ORDER BY rank DESC, l.id DESC
 LIMIT 20;

\echo
\echo '######## PLAN 2 (heaviest): seller fulfilment queue (orders + line count) ########'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT o.id, o.order_number, o.created_at, o.total_minor, o.currency, o.ship_city,
       (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS lines
  FROM orders o
 WHERE o.seller_id = :'busy_seller' AND o.status = 'paid'
 ORDER BY o.created_at, o.id
 LIMIT 20;

\echo
\echo '######## BONUS 3: buyer order history, keyset page 2 (page size 5) ########'
SELECT created_at AS cur_ts, id AS cur_id FROM orders WHERE buyer_id = :'busy_buyer' ORDER BY created_at DESC, id DESC OFFSET 4 LIMIT 1 \gset
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT o.id, o.order_number, o.status, o.total_minor, o.currency, o.created_at
  FROM orders o
 WHERE o.buyer_id = :'busy_buyer' AND (o.created_at, o.id) < (:'cur_ts', :'cur_id')
 ORDER BY o.created_at DESC, o.id DESC
 LIMIT 5;

\echo
\echo '######## BONUS 4: browse a category, cheapest first ########'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT l.id, l.title, l.price_minor, l.currency
  FROM listings l
 WHERE l.category_id = :'some_cat' AND l.status = 'active' AND l.deleted_at IS NULL
 ORDER BY l.price_minor, l.id
 LIMIT 20;

\echo
\echo '######## COUNTERFACTUAL: the same two heavy queries with their index dropped (rolled back) ########'
BEGIN;
DROP INDEX listings_search_gin;
DROP INDEX orders_fulfilment_queue_idx;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT l.id, l.title, l.price_minor, ts_rank(l.search_tsv, q) AS rank
  FROM listings l, websearch_to_tsquery('simple', 'premium lamp') q
 WHERE l.status = 'active' AND l.deleted_at IS NULL AND l.search_tsv @@ q
   AND l.price_minor BETWEEN 100000 AND 3000000
 ORDER BY rank DESC, l.id DESC LIMIT 20;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT o.id, o.order_number, o.created_at, o.total_minor, o.currency, o.ship_city,
       (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS lines
  FROM orders o
 WHERE o.seller_id = :'busy_seller' AND o.status = 'paid'
 ORDER BY o.created_at, o.id
 LIMIT 20;
ROLLBACK;
