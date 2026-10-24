# 1. Requirements

**Product: Duka**, a multi-seller marketplace. Independent sellers list goods, buyers search and order them, the platform takes payment, the seller ships, the buyer confirms and reviews. (Chosen over ride-hailing because the author has already built a ride-hailing system, `ryde`, and the brief says not to reuse one.)

## Who uses it

| Actor | Does |
|---|---|
| **Buyer** (any registered user) | searches, orders, pays, confirms receipt, reviews, erases their account |
| **Seller** (a user with a shop) | publishes listings, manages stock, ships paid orders |
| **Staff** | approves or suspends sellers, takes down reviews, approves returns |
| **System** | payment-provider webhooks, order-expiry job, carrier delivery events |

## Scope decisions (stated so nobody has to ask)

- One order = one buyer + **one** seller. A mixed cart is split into one order per seller by the client or a future `checkout` resource. Not designed here.
- A shop prices and settles in **one currency**. An order is in that currency. No FX.
- Card data never touches Duka. The payment provider holds it; we keep references only.
- Shipping fee is a flat per-shop fee, copied onto the order when it is created.
- Out of scope: auth/login (delegated to an identity provider, we receive `sub` = user id), search ranking beyond keyword relevance, disputes, payouts to sellers, images, carts.

## Functional requirements

| ID | Requirement |
|---|---|
| F1 | A seller creates a listing (title, description, category, price, stock) as a draft, publishes it, can pause and resume it. |
| F2 | A buyer finds listings by keyword, category and price range, sorted sensibly, in pages. |
| F3 | A buyer places an order of one or more items from one seller. The price, title and shipping address are **frozen at that moment**. Stock is reserved. |
| F4 | A buyer pays an order. A failed payment can be retried. The order becomes *paid* only when the provider confirms capture. |
| F5 | A seller sees the queue of paid orders, oldest first, and ships one by entering carrier and tracking number. |
| F6 | A buyer confirms receipt (order completed). Between delivery and completion a return can be accepted (order refunded). |
| F7 | A buyer or seller can cancel before dispatch. Reserved stock returns to the listing. Unpaid orders expire after 30 minutes. |
| F8 | A buyer reviews an item once, and only from an order that is completed. |
| F9 | A user can erase their account. Personal data is destroyed. Financial records survive. |
| F10 | Staff can suspend sellers and remove reviews. |

## Non-functional requirements

| ID | Requirement |
|---|---|
| N1 | Never sell more units than exist, even under concurrent checkout. |
| N2 | Money is exact. No rounding drift, ever. |
| N3 | A retried request (flaky mobile network) never creates a second order or a second charge. |
| N4 | Every order status change is auditable: from, to, who, when. |
| N5 | List endpoints stay fast as data grows (keyset pagination, no `OFFSET`). Search p95 under 200 ms at 1M listings. |
| N6 | Identifiers reveal nothing and cannot be enumerated. |
| N7 | Financial records are retained (assumed 7 years). Personal data is erasable on request. |

## The five most important actions

| # | Action | Actor | Why it is top five |
|---|---|---|---|
| **A1** | Publish a listing | Seller | No supply, no marketplace. |
| **A2** | Search listings | Buyer | The most frequent read; the heaviest query. |
| **A3** | Place an order | Buyer | Where stock, price and address are frozen; the concurrency hot spot. |
| **A4** | Pay for an order | Buyer / provider | Where money moves; must be exactly-once. |
| **A5** | Ship a paid order | Seller | Completes the promise; driven by the fulfilment queue. |

Confirm-receipt, cancel, review and erase are important but are variations on the same patterns; they get full contracts in the API document.

## Traceability: which requirement forces which design decision

| Decision | Because |
|---|---|
| `order_items.unit_price_minor` + `title_snapshot` | F3, N2: the buyer pays what they saw, forever |
| `listings.stock_quantity CHECK >= 0` + reserve-in-trigger | N1 |
| Money as `bigint` minor units + currency | N2 |
| Composite FKs forcing one seller and one currency per order | F3, N2 |
| `Idempotency-Key` header, `idempotency_keys` table | N3 |
| `payments_one_live_per_order` partial unique index | F4, N3 |
| `state_transitions` + triggers, `order_events` | F4, F6, F7, N4 |
| Review FK on `(order_id, buyer_id, 'completed')` | F8 |
| Soft delete + `anonymise_user()` | F9, N7 |
| UUIDv7 ids, random `order_number` | N6 |
| Partial / keyset-friendly indexes | N5 |
| Seller-facing SSE stream | F5 (no polling for the queue) |
