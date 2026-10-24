# 6. Proof that the model holds

Everything here is produced by one command against a local PostgreSQL 18:

```bash
bash db/run_proof.sh        # drops/creates database duka_task3, runs everything, rewrites evidence/
python tools/render_evidence.py   # renders excerpts to evidence/screenshots/*.png (needs Chrome)
```

| Step | File |
|---|---|
| Migration up / down | [`db/migrations/001_init.up.sql`](../db/migrations/001_init.up.sql), [`001_init.down.sql`](../db/migrations/001_init.down.sql). The runner also does down → 0 tables → up → 13 tables |
| Small seed (readable, walks orders through real transitions) | [`db/seed/001_seed_small.sql`](../db/seed/001_seed_small.sql) |
| Bulk seed for plans (20k users, 1k sellers, 200k listings, 300k orders/items, 240k payments, 72k reviews) | [`002_bulk_for_plans.sql`](../db/seed/002_bulk_for_plans.sql), [`003_power_seller.sql`](../db/seed/003_power_seller.sql) |
| Five actions as SQL | [`db/proof/10_five_actions.sql`](../db/proof/10_five_actions.sql) → [`evidence/10_five_actions.txt`](../evidence/10_five_actions.txt) |
| Query plans | [`db/proof/20_query_plans.sql`](../db/proof/20_query_plans.sql) → [`evidence/20_query_plans.txt`](../evidence/20_query_plans.txt) |
| Rejected invalid states | [`db/proof/30_invalid_inserts.sql`](../db/proof/30_invalid_inserts.sql) → [`evidence/30_invalid_inserts.txt`](../evidence/30_invalid_inserts.txt) |
| Erasure and late capture | [`40_erasure.sql`](../db/proof/40_erasure.sql), [`50_late_capture.sql`](../db/proof/50_late_capture.sql) |

**On "screenshots":** the PNGs in `evidence/screenshots/` are renders of the *captured* `psql` output (the text is the real output of the real run), produced by a script, not photographs of a live terminal. If the marker wants a live-terminal screenshot, run `bash db/run_proof.sh` and screenshot `evidence/30_invalid_inserts.txt` or run the file directly with `psql -d duka_task3 -f db/proof/30_invalid_inserts.sql`.

**On loading data:** the bulk seed temporarily disables the *business triggers* (not CHECK or FK constraints) on five tables, otherwise it would drive 300k orders through every status one `UPDATE` at a time. It then **audits** itself: orders whose `items_subtotal ≠ sum(items)` = **0**, listings whose rating cache ≠ live reviews = **0** (see `evidence/02_bulk_seed.txt`). The small seed, which the five actions and rejections use, goes through every trigger.

---

## 6.1 The five actions

(Excerpts; full output in `evidence/10_five_actions.txt`. Mutating actions run in a transaction that is rolled back so the proof can be repeated.)

| | SQL | Result seen |
|---|---|---|
| **Q1** publish a listing | `INSERT … listings` (draft) then `UPDATE … SET status='active'` | row returned with `status = active` |
| **Q2** search | `websearch_to_tsquery` + `@@` + price range, `ORDER BY rank DESC, id DESC LIMIT` | ranked rows (`Premium lamp …`) |
| **Q3** place order | `INSERT orders`, `INSERT order_items(order_id, listing_id, quantity)` | price/title snapshotted (`350000`), subtotal `700000`, total `900000` (= 700000 + the seller's 200000 fee), `seller_shop_name_snapshot = Lagos Gadgets`, stock **98 → 96** |
| **Q4** pay | `INSERT payments` → `authorized` → `captured` → `UPDATE orders SET status='paid'` | order `paid` with `paid_at` set by trigger; `order_events` shows `∅→pending_payment (buyer)`, `pending_payment→paid (system)` |
| **Q5** fulfilment | queue `WHERE seller_id=$1 AND status='paid' ORDER BY created_at LIMIT 20`, then `UPDATE … status='shipped', carrier, tracking_number` | one order in the queue; shipped with `shipped_at` set |

## 6.2 Query plans on the two heaviest queries

Data: 200,005 listings, 300,004 + 60,000 orders. PostgreSQL 18, `EXPLAIN (ANALYZE, BUFFERS)`. Full plans in `evidence/20_query_plans.txt`; images: `evidence/screenshots/plan_*.png`.

**Heaviest #1, keyword search with price filter, ranked** ([screenshot](../evidence/screenshots/plan_1_search_gin.png))

```
Limit
  -> Sort (top-N heapsort)
       -> Bitmap Heap Scan on listings l   (actual rows=478)
            Recheck Cond: search_tsv @@ 'premium & lamp' AND status='active' AND deleted_at IS NULL
            Filter: price_minor BETWEEN 100000 AND 3000000   (Rows Removed by Filter: 347)
            -> Bitmap Index Scan on listings_search_gin   (actual rows=1139)
Execution Time: ~17 ms
```

**Heaviest #2, seller fulfilment queue with line counts** ([screenshot](../evidence/screenshots/plan_2_seller_queue.png)), for the seller with 60,341 orders:

```
Limit
  -> Index Scan using orders_fulfilment_queue_idx on orders o   (actual rows=20)
       Index Cond: seller_id = '…'
       SubPlan: Aggregate -> Index Only Scan using order_items_one_line_per_listing on order_items oi
Execution Time: ~0.8 ms
```

**Counterfactual: the same queries with their index dropped** (inside a rolled-back transaction) ([screenshot](../evidence/screenshots/plan_counterfactual_without_indexes.png)):

| Query | With index | Without | What the planner does without |
|---|---|---|---|
| Search | **~17 ms** (Bitmap Index Scan, GIN) | **~142 ms** | Parallel Seq Scan over 200k rows, 66,509 rows/worker filtered |
| Fulfilment queue | **~0.8 ms** | **~35.6 ms** | walks the seller's entire order history, 58,362 rows removed by filter |

Two bonus plans (`PLAN 3/4`) confirm the buyer's keyset order history (`orders_buyer_history_idx`, 0.03 ms for a 5-row page) and category browse by price (`listings_browse_price_idx`, 0.6 ms).

*Honest note:* timings vary run to run; the ratios and the **node types** are what matter. Also, before I added the high-volume seller the queue index made *no measurable difference* (0.29 ms vs 0.30 ms at ~300 orders per seller). It is justified by how it scales, not by the average seller (details in §3.7 of [03-hard-questions.md](03-hard-questions.md)).

## 6.3 Invalid states the database rejects

Each is in its own rolled-back transaction. Full text: `evidence/30_invalid_inserts.txt`.

### Required 1: overselling ([screenshot](../evidence/screenshots/violation_1_oversell.png))
Bluetooth speaker has `stock_quantity = 0`. Ordering one:
```
ERROR:  23514: new row for relation "listings" violates check constraint "listings_stock_nonneg"
DETAIL:  Failing row contains (… Bluetooth speaker …, 2800000, NGN, -1, active, …)
CONTEXT:  SQL statement "UPDATE listings SET stock_quantity = stock_quantity - NEW.quantity …"
          PL/pgSQL function order_items_after_insert()
CONSTRAINT NAME:  listings_stock_nonneg
```

### Required 2: a review for an order that is not completed ([screenshot](../evidence/screenshots/violation_2_review_without_completed_order.png))
The order is `paid`.
```
ERROR:  23503: insert or update on table "reviews" violates foreign key constraint "reviews_order_completed_fk"
DETAIL:  Key (order_id, buyer_id, order_status)=(0190a000-…-000000000003, 0190a000-…-000000000003, completed) is not present in table "orders".
```

### Required 3: forbidden state transition ([screenshot](../evidence/screenshots/violation_3_illegal_transition.png))
```
UPDATE orders SET status = 'shipped', carrier = 'GIGL', tracking_number = 'X' WHERE id = '…0001';   -- order is completed
ERROR:  DK001: illegal order transition: completed -> shipped
```

### Extra rejections that appear in the file (all pass)

| # | Attempt | Rejected with |
|---|---|---|
| 4 | `cancelled → paid` (the late-webhook case) | `DK001 illegal order transition: cancelled -> paid` |
| 5 | `shipped → cancelled` | `DK001 illegal order transition: shipped -> cancelled` |
| 6 | order → `paid` with no captured payment | `DK003 cannot be paid without a captured payment` |
| 7 | second live payment for one order | `23505 payments_one_live_per_order` |
| 8 | payment amount ≠ order total | `DK003 payment amount 1 != order total 3000000` |
| 9 | item from another seller in an order | `23503 order_items_order_fk` |
| 10 | seller buys own shop | `DK003 a seller cannot buy from their own shop` |
| 11 | ship to someone else's address | `23503 orders_ship_address_belongs_to_buyer` |
| 12 | price `0`; USD listing in an NGN shop | `23514 listings_price_positive`; `23503 listings_seller_currency_fk` |
| 13 | insert an order already `completed` | `DK001 orders must be created as pending_payment, not completed` |
| 14 | change a price on a finished order line | `DK002 order_items are immutable once written` |
| 15 | delete from the audit trail | `DK002 order_events is append-only` |
| 16 | second review of the same line | `23505 reviews_one_per_item` |

## 6.4 The late-capture scenario (why `cancelled → paid` is forbidden)

[`evidence/50_late_capture.txt`](../evidence/50_late_capture.txt), [screenshot](../evidence/screenshots/late_capture_cancelled_to_paid.png):

```
-- expiry job cancels the unpaid order
-- provider's capture webhook arrives afterwards: the payment row records the truth (captured)
UPDATE orders SET status = 'paid' …;
ERROR:  DK001: illegal order transition: cancelled -> paid

-- reconciliation query (run by a job, feeds the refund queue)
SELECT o.order_number, o.status, p.status, p.amount_minor, p.currency
  FROM orders o JOIN payments p ON p.order_id = o.id
 WHERE o.status = 'cancelled' AND p.status = 'captured';
  DK-3534E3E41CFA | cancelled | captured | 3000000 | NGN
```

## 6.5 Erasure

[`evidence/40_erasure.txt`](../evidence/40_erasure.txt), [screenshot](../evidence/screenshots/erasure.png). `anonymise_user(bola)` is refused while an order is `paid`. For a user with only a completed order, it nulls `email`/`full_name`, scrubs the ship-to snapshot to `[erased]`, sets `deleted_at`, and the order, total and `captured` payment are untouched; a following attempt to edit the erased order is still rejected (`DK002`).
