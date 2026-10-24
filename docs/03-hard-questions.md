# 3. The hard questions

Requirement IDs (F1, N2, …) refer to [01-requirements.md](01-requirements.md).

---

## 3.1 Normalisation: where does one fact live?

**Default rule:** every fact lives in exactly one row. A seller's shop name is in `sellers.shop_name`; a listing's category is in `listings.category_id`.

**Deliberate exceptions.** A copy is justified only when the fact is about *a moment in time* rather than about the current state of the world, or when a derived value is read far more than it changes. Each copy below has a reason, an owner that is allowed to write it, and a mechanism that stops it drifting.

| # | Copy | Source of truth | Why the copy exists | What keeps it honest |
|---|---|---|---|---|
| D1 | `order_items.unit_price_minor`, `title_snapshot` | `listings.price_minor`, `title` | The price the buyer **agreed to** is a historical fact, not a function of today's price (F3, N2). | Written once by `order_items_guard()` from the listing, overwriting whatever the client sent; lines are immutable afterwards (DK002). |
| D2 | `orders.ship_*` (recipient, address lines, city, postal code, country), `seller_shop_name_snapshot`, `shipping_fee_minor` | `addresses`, `sellers` | The parcel goes where the order said, even if the buyer edits or deletes the address next week. A receipt must show the shop name and fee as they were. | Filled by `orders_before_insert()`; frozen by `orders_before_update()`. The only legal later change is erasure (D2 note below). |
| D3 | `orders.items_subtotal_minor` | `sum(order_items.line_total_minor)` | Every order list and every payment amount needs the total; summing items on each read is waste. | Only changed by the `order_items` insert trigger; frozen once the order leaves `pending_payment`. The bulk-load audit (`evidence/02_bulk_seed.txt`) proves `subtotal = sum(items)` for 300k orders. |
| D4 | `listings.rating_sum`, `rating_count` | `reviews` | The search result card shows the rating for 20 listings per page; aggregating reviews per row is not affordable (N5). | `reviews_aggregate()` trigger; `CHECK 5·count ≥ sum ≥ count`; stored as sum + count, never as a decimal average. |
| D5 | `order_items.seller_id`, `currency`; `listings.currency`; `reviews.order_id`, `listing_id`, `buyer_id` | the parent rows | They are the columns that make **composite foreign keys** possible, which in turn make cross-seller / cross-currency / wrong-buyer rows unrepresentable. | They *are* the FK; a copy that disagrees with its parent cannot be inserted. |

### Defending D1, "a fact that lives in two places"

`listings.price_minor` says what the item costs *today*. `order_items.unit_price_minor` says what *this buyer agreed to pay*. They are different facts that happen to share a value on the day of purchase. If the seller raises the price tomorrow and the order looked the price up, three things break: the buyer's receipt changes after the fact, the amount we already charged no longer matches the order, and a refund would be computed on the wrong figure. The copy is not a performance trick; it is the *only* correct place to record the agreement. The same reasoning is why `orders.total_minor` is generated from stored parts and not recomputed from live listings.

### Defending D2, and the subtle part

The ship-to snapshot is a copy of **personal data**, which is a liability under erasure laws (F9, N7). Two rules resolve the tension:

1. Only the *minimum* needed to deliver and to evidence the sale is copied. The buyer's name and email are **not** copied onto the order; only `ship_recipient`, which may legitimately differ from the account name ("deliver to my mother").
2. The snapshot is scrubbed by `anonymise_user()` once the order is terminal, using a narrowly-scoped session flag (`app.erasure`) that the frozen-column guard honours for exactly the `ship_*` columns. Proof: [`evidence/40_erasure.txt`](../evidence/40_erasure.txt) shows `ship_recipient = '[erased]'` with the total and payment still intact, and a following tamper attempt still rejected.

The seller's *shop name* is copied without that concern because it is public business data, not personal data. The asymmetry is deliberate.

**Not denormalised, on purpose:** the buyer's name/email on orders (see above), and the seller's currency on payments beyond the FK-checked `currency` (a payment always equals its order's currency by composite FK).

---

## 3.2 Money

**Rule: every monetary amount is a `bigint` count of minor units (kobo, cents), and every row that holds one also holds a `currency char(3)` ISO-4217 code in the same row. No `numeric`, no `float`, no `money` type, anywhere.**

Applied everywhere money appears:

| Column | Table | Currency column beside it |
|---|---|---|
| `flat_shipping_fee_minor` | sellers | `currency` |
| `price_minor` | listings | `currency` |
| `unit_price_minor`, `line_total_minor` | order_items | `currency` |
| `items_subtotal_minor`, `shipping_fee_minor`, `total_minor` | orders | `currency` |
| `amount_minor` | payments | `currency` |

Why, and how the model enforces it:

- ₦45,000.00 is stored as `4500000`. Integer arithmetic is exact; `0.1 + 0.2` problems cannot occur. Totals are generated columns (`total_minor`, `line_total_minor`), so there is no application code that can sum them wrongly.
- The currency sits **in the same row** so an amount can never be read without its unit, and composite foreign keys (`listings→sellers`, `orders→sellers`, `order_items→orders` and `→listings`, `payments→orders` all on `(…, currency)`) make it **impossible to mix currencies** within an order or pay in the wrong one. Proof: invalid insert 12, `listings_seller_currency_fk` rejects a USD listing for an NGN shop.
- Positive amounts: `price_minor > 0`, `amount_minor > 0`, others `>= 0`.
- Nothing in v1 divides money. When a percentage appears (a platform commission), it will be stored as integer **basis points** and applied as `amount * bps / 10000` with a documented rounding rule (round half up) in one function. There is no floating point in the path.
- **A caveat I checked, not assumed:** PostgreSQL silently *rounds* a decimal assigned to a `bigint` column (`12.5` becomes `13`). The database cannot catch a decimal that reaches it, so the **API boundary rejects non-integers** (`type: integer` in the schema, 422 `validation_failed`). The API money shape is `{"amount_minor": 4500000, "currency": "NGN"}`; JSON integers are exact up to 2^53, about ₦90 trillion in kobo.

---

## 3.3 Status and state

Statuses are **enums** (no free text) and every change is checked against the `state_transitions` table by a trigger. Anything not in that table is forbidden.

### Order lifecycle

![Order state machine](../diagrams/order_state.png)

Source: [`diagrams/order_state.mmd`](../diagrams/order_state.mmd). Payment and listing machines: [`payment_state.mmd`](../diagrams/payment_state.mmd), [`listing_state.mmd`](../diagrams/listing_state.mmd).

### Full order transition matrix

✓ = allowed (a row in `state_transitions`). Every other cell is **forbidden** and raises `DK001`.

| from ↓ \ to → | pending_payment | paid | shipped | delivered | completed | cancelled | refunded |
|---|---|---|---|---|---|---|---|
| **(birth)** | ✓ only | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **pending_payment** | – | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| **paid** | ✗ | – | ✓ | ✗ | ✗ | ✓ | ✗ |
| **shipped** | ✗ | ✗ | – | ✓ | ✗ | **✗** | ✗ |
| **delivered** | ✗ | ✗ | ✗ | – | ✓ | ✗ | ✓ |
| **completed** | ✗ | ✗ | ✗ | ✗ | – | ✗ | **✗** |
| **cancelled** | ✗ | **✗** | ✗ | ✗ | ✗ | – | ✗ |
| **refunded** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | – |

### The forbidden transitions that are not obvious

These are the ones I only found by drawing the table, because each one is something a real system *will try* to do:

| Forbidden | Why it is forbidden | What happens instead |
|---|---|---|
| **cancelled → paid** | A buyer abandons checkout, the order expires and is cancelled, stock is released. Then the provider's webhook arrives: the payment *did* capture. Resurrecting the order would sell stock that may already belong to someone else. | The payment row still moves to `captured` (the money really moved). The order stays cancelled. A reconciliation query finds `cancelled` orders with a `captured` payment and refunds them. (Query in [06-proof.md](06-proof.md).) |
| **shipped → cancelled** | The goods are in a van. A "cancel" here is a lie about reality, and restocking would put inventory on the shelf that is on the road. | Delivery, then a **return**: `delivered → refunded`. |
| **completed → refunded** | `completed` is the buyer's acknowledgement that closes the return window. Allowing it would make `completed` meaningless, and a review (which requires `completed`) could exist for a refunded order. | Out-of-window goodwill refunds are a payment-level adjustment handled by staff, not an order state. Known gap, noted in §3.6. |
| **paid → delivered** | Cannot be delivered without being shipped; would skip the tracking number the buyer relies on. | Must pass through `shipped`. |
| **delivered → shipped / any backwards move** | History is append-only. A mistake is corrected by a new event, not by rewinding. | n/a |
| **active → draft** (listing) | Orders reference the listing; pulling it back to "draft" implies it was never public. | `active → paused`. |

### What enforces it (three layers, innermost wins)

1. **Type:** `order_status` is an enum; `'complete'` or `'Shipped '` is not a value.
2. **`state_transitions` + `assert_transition()`:** called from the `orders`, `payments` and `listings` update triggers. A status change with no matching row raises SQLSTATE `DK001`. Adding a transition is a one-line data change in a migration, visible in review.
3. **Guards around the transition,** in the same trigger:
   - an order can only be **born** `pending_payment` (`enforce_initial_status`), so no `INSERT … status='completed'`;
   - `→ paid` requires a **captured** payment and a non-empty order; `→ refunded` requires a **refunded** payment;
   - terminal orders are fully read-only (`DK002`), except the ship-to scrub during erasure;
   - the matching timestamp is set by the trigger and required by a CHECK (`orders_shipped_has_tracking`, `orders_cancelled_has_cancel_info`, …);
   - every change writes an `order_events` row (append-only, `DK002` on update/delete) with `from`, `to`, `actor`.

The application never decides legality; it only asks. The API maps `DK001` to **409 `invalid_state_transition`**.

**Order of checks matters and I got it wrong first.** My first version checked "is this order read-only?" before "is this transition allowed?", so `completed → shipped` was reported as *DK002 read-only* instead of *DK001 illegal transition*. The distinction matters because the API returns different errors for "you can't do that now" and "you can't edit that." The transition check now runs first.

**Honest limits.** A database superuser or table owner can `DISABLE TRIGGER` (I did exactly that, for the bulk loader, which is why it is a seed script and not a code path). Production application roles are not table owners. The other half of the defence is that the application role has only `INSERT/SELECT/UPDATE` on these tables and no `ALTER`.

### Payment lifecycle
`pending → authorized | captured | failed`, `authorized → captured | voided`, `captured → refunded`. `failed`, `voided`, `refunded` are terminal; a retry is a **new row**. Non-obvious forbidden: **failed → captured** (a late success on a failed attempt must be a new payment, otherwise the "one live payment" rule and the audit trail lie).

---

## 3.4 Time

- Every mutable table has `created_at` and `updated_at` (`timestamptz`, UTC, default `now()`). `updated_at` is maintained by a `BEFORE UPDATE` trigger (`set_updated_at`), so no code path can forget it. A CHECK keeps `updated_at >= created_at`.
- **Deliberate exceptions:** `order_events` and `payment_events` are immutable ledgers, so they carry only `created_at`; an `updated_at` there would be a field that is always wrong. `state_transitions` is reference data with neither.
- Business timestamps (`paid_at`, `shipped_at`, …) are set by the transition trigger and each is required by its status via CHECK.
- Display time zone is a client concern; the API always sends ISO-8601 UTC (`2026-10-24T21:31:36Z`).

### Soft delete or hard delete, per entity

The rule: **delete what has no legal reason to survive and no one references; anonymise what is referenced by money.** A row that an invoice points to cannot be erased, but the *person* in it can.

| Entity | Strategy | Reasoning |
|---|---|---|
| users | **Soft** (`deleted_at`) + **anonymise** (`anonymise_user()`) | Orders and payments reference the buyer and must be kept for tax/audit (N7). Email, name, phone are nulled; the row stays as an opaque id. |
| addresses | Soft + scrubbed on erasure | Orders hold their own snapshot, so the address row is purely PII. |
| sellers | Soft + anonymise | Orders and listings reference it. Shop slug is freed for reuse. |
| listings | Soft | Past `order_items` point to it and reviews hang off it. Hidden from search by index predicate `deleted_at IS NULL`. |
| payment methods | n/a in v1 (provider holds them) | Nothing to delete locally. |
| reviews | Soft (moderation) | Takedown must be reversible and auditable; the rating aggregate is adjusted by trigger. |
| categories | **No delete** (`is_active = false`) | Listings reference it; FK `RESTRICT`. |
| **orders, order_items, payments, payment_events, order_events** | **Never deleted** | Financial records. No `deleted_at` column exists, so it cannot even be attempted. Lines and events are additionally protected by triggers. |
| idempotency_keys | **Hard**, after 24 h | Ephemeral, no compliance value. |
| (future) live driver/GPS-like data | **Hard** | Not in this product; stated to show where the line would fall. |

Erasure proof: `anonymise_user()` **refuses** while the user has an order in `pending_payment/paid/shipped/delivered` (money or goods in flight) and otherwise nulls the PII, scrubs ship-to snapshots on terminal orders, closes the shop and soft-deletes its listings. See [`evidence/40_erasure.txt`](../evidence/40_erasure.txt).

---

## 3.5 Identifiers

**All primary keys are UUIDs generated by `uuidv7()`. No auto-increment integers, anywhere. The customer-facing order reference is 12 random hex characters (`DK-9F3A…`), not a counter.**

Security reasons, in order of importance:

1. **Enumeration / IDOR.** With `/orders/1041`, an attacker (or a bug) walks `1042, 1043…` and every missing ownership check becomes a data breach. A 122-bit random space cannot be walked. (This is defence in depth: **every query still filters by the caller's id**; unguessable ids make a missed check hard to exploit, not impossible.)
2. **Business-intelligence leak.** Sequential order numbers let a competitor sample two of their own orders a week apart and compute your weekly volume. Same for seller and listing counts.
3. **Cross-system safety.** Ids are generated by the database or any app node without coordination, so there is no central counter to contend on, and rows from staging cannot collide with production.

Why **v7** and not v4: v7 puts a millisecond timestamp in the high bits, so new rows land at the right edge of the B-tree (good for insert locality and for keyset pagination, which orders by `(created_at, id)`), and the SSE stream can resume with `id > last_event_id`. The trade-off, stated honestly: a v7 id reveals *when* the row was created. It does not reveal how many exist or what the next one is, which is the leak that matters. If creation time of a specific entity were sensitive, that entity would use `gen_random_uuid()` (v4).

`order_number` collisions: 12 hex = 48 bits; the unique index rejects a collision and the service retries. Expected collision probability at one million orders is under 0.2 %.

---

## 3.6 Constraints

### Per table

(PK = primary key. "Partial unique" = unique index with a `WHERE`.)

| Table | Unique | Foreign keys | Check constraints (names where they matter) |
|---|---|---|---|
| users | PK; partial unique `lower(email)` where live | n/a | email shape; E.164 phone; `users_pii_present_unless_erased`; `updated_at >= created_at` |
| addresses | PK; `(id, user_id)`; partial unique `user_id` where default and live (`addresses_one_default_per_user`) | `user_id→users` | country `^[A-Z]{2}$`; phone; length limits |
| sellers | PK; `user_id`; `(id, currency)`; partial unique `shop_slug` where live | `user_id→users` | currency shape; slug shape; `sellers_shipping_fee_nonneg` |
| categories | PK; `slug` | `parent_id→categories` | `categories_not_own_parent` |
| listings | PK; `(id, seller_id, currency)` | `(seller_id, currency)→sellers(id, currency)` (`listings_seller_currency_fk`); `category_id→categories` | `listings_price_positive`; **`listings_stock_nonneg`**; `listings_rating_aggregate_sane`; title/description lengths |
| orders | PK; `order_number`; `(id, seller_id, currency)`; `(id, currency)`; `(id, buyer_id, status)` | `buyer_id→users`; `(seller_id, currency)→sellers`; **`(shipping_address_id, buyer_id)→addresses(id, user_id)`** | `orders_shipped_has_tracking`, `orders_paid_has_paid_at`, `orders_delivered_has_delivered_at`, `orders_completed_has_completed_at`, `orders_cancelled_has_cancel_info`, `orders_timestamps_ordered`, amounts `>= 0` |
| order_items | PK; **`(order_id, listing_id)`**; `(id, order_id, listing_id)` | **`(order_id, seller_id, currency)→orders`**; **`(listing_id, seller_id, currency)→listings`** | quantity 1..999; `unit_price_minor > 0` |
| order_events | PK | `order_id→orders` | append-only trigger |
| payments | PK; partial unique **`order_id` where status in (pending, authorized, captured)** (`payments_one_live_per_order`); partial unique `(provider, provider_reference)` | `(order_id, currency)→orders(id, currency)` | `amount_minor > 0`; `payments_failed_has_code`; `payments_captured_has_ts` |
| payment_events | PK `provider_event_id` | `payment_id→payments` | n/a |
| reviews | PK; **`order_item_id`** (`reviews_one_per_item`) | **`(order_item_id, order_id, listing_id)→order_items`**; **`(order_id, buyer_id, order_status)→orders(id, buyer_id, status)`** | `reviews_order_must_be_completed`; `reviews_rating_range` |
| idempotency_keys | PK `(principal_id, idem_key)` | n/a | key length 8..128 |
| state_transitions | PK `(entity, from, to)` | n/a | `from <> to` |

### Which invalid states are now impossible?

Each row names what enforces it and where it is demonstrated. "Evidence" numbers refer to [`evidence/30_invalid_inserts.txt`](../evidence/30_invalid_inserts.txt); R = one of the three required rejections.

| Invalid state | Enforced by | Evidence |
|---|---|---|
| Selling more units than exist (two buyers, last item) | `listings_stock_nonneg`; the reserve `UPDATE` takes a row lock so concurrent orders serialise, the second drives stock to −1 and fails | **R1** |
| A review for an order that is not completed | FK `reviews_order_completed_fk` on `(order_id, buyer_id, 'completed')`; plus `reviews_order_must_be_completed` | **R2** |
| An order going completed→shipped, cancelled→paid, shipped→cancelled, or being born "completed" | `assert_transition`, `enforce_initial_status` (`DK001`) | **R3**, 4, 5, 13 |
| An order marked *paid* with no captured payment | `orders_before_update` (`DK003`) | 6 |
| Two live payments for one order (double charge) | `payments_one_live_per_order` | 7 |
| A payment that is not for the order's total | `payments_guard` (`DK003`) | 8 |
| An order containing items from two sellers or two currencies | composite FK `order_items_order_fk` | 9 |
| A seller buying from their own shop | `orders_before_insert` (`DK003`) | 10 |
| Shipping to someone else's address | FK `orders_ship_address_belongs_to_buyer` | 11 |
| Free items, negative prices, a USD listing in an NGN shop | `listings_price_positive`, `listings_seller_currency_fk` | 12 |
| Rewriting the price on a finished order line | `order_items_guard` (`DK002`) | 14 |
| Editing or deleting the audit trail | `forbid_mutation` trigger | 15 |
| Two reviews of the same purchased item | `reviews_one_per_item` | 16 |
| Two default addresses for one user | `addresses_one_default_per_user` | by design |
| A shipped order with no tracking number | `orders_shipped_has_tracking` | by design |

**Rules I considered and did not add:** limiting a buyer to one open `pending_payment` order per seller. Nothing in F1 to F10 requires it, and adding it would block legitimate parallel carts. The ride-hailing equivalent ("one active trip per rider") has no counterpart here, and I would rather say so than invent one.

**Known gaps.** (1) Goodwill refunds after `completed` have no order state (§3.3). (2) `shipped → refunded` for lost parcels is not modelled; if the carrier-loss requirement appears it is a single `state_transitions` row plus a guard. (3) Enums cannot enforce that a *seller's* `currency` never changes after listings exist; the composite FKs make a change fail loudly instead (`ON UPDATE NO ACTION`).

---

## 3.7 Indexes

Every index below exists to serve a named query. Measured on 200k listings, 300k orders (+60k historical orders for one power seller), PostgreSQL 18: [`evidence/20_query_plans.txt`](../evidence/20_query_plans.txt).

| Query / endpoint | Index | Why this shape |
|---|---|---|
| **A1** seller's catalogue `GET /sellers/me/listings` | `listings_seller_idx (seller_id, created_at DESC, id DESC) WHERE deleted_at IS NULL` | filter + keyset order in one scan |
| **A1** publish: lookup by id | `listings` PK | |
| **A2** keyword search | `listings_search_gin` GIN on `search_tsv`, **partial** `WHERE status='active' AND deleted_at IS NULL` | drafts, paused and deleted rows never bloat the index |
| **A2** browse category, newest | `listings_browse_new_idx (category_id, created_at DESC, id DESC)` partial (active, live) | equality + sort + tiebreak |
| **A2** browse category, price | `listings_browse_price_idx (category_id, price_minor, id)` partial (active, live) | serves `price_asc` and (backward) `price_desc` |
| **A3** place order: uniqueness and `order_id` lookups | `order_items_one_line_per_listing (order_id, listing_id)` | doubles as the `order_id` index |
| **A3** listing row lock + stock | `listings` PK | |
| **A3** buyer history `GET /orders` | `orders_buyer_history_idx (buyer_id, created_at DESC, id DESC)` | keyset page |
| **A3/A4** expiry sweeper | `orders_pending_expiry_idx (created_at) WHERE status='pending_payment'` | the unpaid set is tiny; index is tiny |
| **A4** payments of an order | `payments_order_idx (order_id, created_at)` | |
| **A4** one live payment / webhook lookup | `payments_one_live_per_order`, `payments_provider_ref_uq` | constraint and lookup are the same index |
| **A4** webhook dedupe | `payment_events` PK `provider_event_id` | |
| **A5** seller fulfilment queue | `orders_fulfilment_queue_idx (seller_id, created_at, id) WHERE status='paid'` | oldest-first, only paid rows |
| **A5** seller's all orders | `orders_seller_history_idx (seller_id, created_at DESC, id DESC)` | |
| Order timeline `GET /orders/{id}/events` and SSE resume | `order_events_order_idx (order_id, created_at)` | |
| Listing's reviews page | `reviews_listing_idx (listing_id, created_at DESC, id DESC) WHERE deleted_at IS NULL` | |
| Buyer's addresses | `addresses_user_live_idx (user_id) WHERE deleted_at IS NULL` | |
| Idempotency purge | `idempotency_keys_expiry_idx (expires_at)` | |
| Login-by-email, slug lookup | partial unique indexes | the constraint is the index |

**Plan results.** Search (`premium lamp`, price filter) uses a **Bitmap Index Scan on `listings_search_gin`**, about **17 ms**; with the index dropped it falls to a parallel sequential scan of 200k rows, about **142 ms**. The fulfilment queue uses **`orders_fulfilment_queue_idx`** in **0.8 ms** for a seller with 60,341 orders; without it the planner walks the seller's whole history and discards 58,362 rows, **35.6 ms**.

**An honest result I did not expect.** At first the queue index made no difference (0.29 ms vs 0.30 ms) because each seller had only ~300 orders. It only earns its place for a high-volume seller whose history grows without bound while the paid queue stays small, which is precisely the seller you most want to be fast. I kept it, but the reason is *scaling shape*, and the evidence file shows both regimes.

**Deliberately not indexed:** foreign-key columns that no query filters on (`order_items.listing_id`, `orders.shipping_address_id`, `listings.category_id` beyond the browse indexes). PostgreSQL does not need them for correctness here, because the parents (listings, addresses, orders) are never hard-deleted, so there is no cascade scan to speed up. Each unneeded index would slow every write on the hottest tables. I also removed a `UNIQUE (id, order_id)` on payments that no foreign key used.
