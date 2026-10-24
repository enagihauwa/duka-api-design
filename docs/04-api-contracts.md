# 4b. API contracts

Read [04-api-conventions.md](04-api-conventions.md) first: auth, money, errors (E-STD), idempotency, and the pagination/filter/sort contract apply to everything here.

Notation: **R** = required, **O** = optional. `Idem:` states whether the call is idempotent and how. "Errors" lists everything **in addition to E-STD**.

## Index

| | Endpoint | Action |
|---|---|---|
| **A1** | `POST /v1/listings` · `POST /v1/listings/{id}/publish` | seller publishes a listing |
| **A2** | `GET /v1/listings` | buyer searches |
| **A3** | `POST /v1/orders` | buyer places an order |
| **A4** | `POST /v1/orders/{id}/payments` · `POST /v1/webhooks/payments/{provider}` | buyer pays |
| **A5** | `GET /v1/sellers/me/orders` · `POST /v1/orders/{id}/ship` | seller works the queue and ships |
| | [Users](#users) · [Addresses](#addresses) · [Sellers](#sellers) · [Categories](#categories) · [Listings (rest)](#listings-other-operations) · [Orders (rest)](#orders-other-operations) · [Payments (reads)](#payments-reads) · [Reviews](#reviews) · [Staff](#staff) | basic operations per entity |

## Shared response schemas

```jsonc
// Money
{ "amount_minor": 4500000, "currency": "NGN" }

// ListingSummary: used in lists (no description, no stock count)
{ "id": "uuid", "title": "string", "price": Money, "category_id": "uuid",
  "seller": { "id": "uuid", "shop_name": "string", "shop_slug": "string" },
  "rating": { "count": 12, "sum": 54 },          // average = sum/count, client divides
  "in_stock": true, "created_at": "ts" }

// Listing: single-resource view
{ ...ListingSummary, "description": "string", "stock_quantity": 10 /* sellers only; others see in_stock */,
  "status": "draft|active|paused", "updated_at": "ts" }

// Order
{ "id": "uuid", "order_number": "DK-9F3A1C0B77E2", "status": "paid",
  "seller": { "id": "uuid", "shop_name": "string" },        // shop name as at order time
  "items": [ { "id": "uuid", "listing_id": "uuid", "title": "string",   // title at purchase
               "quantity": 2, "unit_price": Money, "line_total": Money } ],
  "items_subtotal": Money, "shipping_fee": Money, "total": Money,
  "ship_to": { "recipient": "string", "line1": "string", "line2": "string|null", "city": "string",
               "region": "string|null", "postal_code": "string", "country": "NG" },
  "shipment": { "carrier": "string|null", "tracking_number": "string|null" },
  "payment": { "id": "uuid", "status": "captured" } /* latest attempt, or null */,
  "timestamps": { "created_at": "ts", "paid_at": "ts|null", "shipped_at": "ts|null",
                  "delivered_at": "ts|null", "completed_at": "ts|null", "cancelled_at": "ts|null" },
  "cancelled_by": "buyer|seller|system|staff|null" }

// OrderSummary: used in lists
{ "id": "uuid", "order_number": "string", "status": "string", "seller": {"id":"uuid","shop_name":"string"},
  "total": Money, "item_count": 3, "created_at": "ts" }

// Payment
{ "id": "uuid", "order_id": "uuid", "status": "pending|authorized|captured|failed|voided|refunded",
  "amount": Money, "provider": "paystack", "failure_code": "string|null", "created_at": "ts" }

// Review
{ "id": "uuid", "order_item_id": "uuid", "listing_id": "uuid", "rating": 5, "body": "string|null", "created_at": "ts" }

// Address
{ "id": "uuid", "recipient_name": "string", "line1": "string", "line2": "string|null", "city": "string",
  "region": "string|null", "postal_code": "string", "country": "NG", "phone_e164": "string|null", "is_default": true }
```

---

# A1: Seller publishes a listing

A listing is created as a **draft**, then published. Two steps because drafting is cheap and repeatable, while publishing is the point where the seller's status and the listing's completeness are checked.

## `POST /v1/listings`: create draft

Auth: seller. **Idem:** requires `Idempotency-Key`; a retry replays the stored `201`.

| Field | Type | | Rule |
|---|---|---|---|
| title | string | R | 3 to 140 chars after trim |
| description | string | O | ≤ 5000, default `""` |
| category_id | uuid | R | an active category |
| price | Money | R | `amount_minor` integer ≥ 1; `currency` must equal the shop's currency |
| stock_quantity | integer | R | ≥ 0 |

**201 Created**, `Location: /v1/listings/{id}`, body `Listing` with `status: "draft"`.

| Status | `code` | When |
|---|---|---|
| 400 | `idempotency_key_required` | header missing |
| 403 | `not_a_seller` | caller has no shop |
| 409 | `idempotency_in_progress` | same key still running |
| 422 | `validation_failed` | field errors (`price.amount_minor` not an integer or < 1, title length, negative stock, unknown/inactive category) |
| 422 | `currency_mismatch` | `price.currency` ≠ shop currency |
| 422 | `idempotency_key_reuse` | key reused with a different body |

## `POST /v1/listings/{id}/publish`: draft → active

Auth: owning seller. No body. **Idem:** by state. Publishing an already-active listing returns **200** with the listing.

**200 OK** body `Listing` with `status: "active"`.

| Status | `code` | When |
|---|---|---|
| 403 | `seller_not_active` | shop is `pending_review` or `suspended`; enforced by the DB guard `listings_guard` (`DK003`). Drafts can be created before approval; publishing cannot |
| 404 | `not_found` | not yours / does not exist / deleted |
| 409 | `invalid_state_transition` | listing is `paused` (use `/resume`) |

---

# A2: Buyer searches listings

## `GET /v1/listings`

Auth: any authenticated user (public browsing may later drop auth). Returns **active, non-deleted** listings only.

**Query parameters**

| Param | Type | Rule |
|---|---|---|
| `q` | string | keyword(s), 1 to 100 chars, web-search syntax (`"exact phrase"`, `-exclude`). Matches title + description. |
| `category_id` | uuid | listings in this category **and its descendants** (the service expands the tree to a list of ids) |
| `seller_id` | uuid | only this shop |
| `currency` | ISO code | required if either price bound is given |
| `min_price_minor` | integer | inclusive, ≥ 0 |
| `max_price_minor` | integer | inclusive |
| `in_stock` | boolean | `true` hides stock 0 |
| `sort` | enum | `relevance` (default when `q` present), `-created_at` (default otherwise), `price_minor`, `-price_minor` |
| `limit`, `cursor` | | standard |

**Allowed combinations** (each is served by an index; others are refused so a request can never trigger a table scan):

| `q` | `category_id` | `sort` allowed | Index |
|---|---|---|---|
| present | optional | `relevance`, `-created_at` | `listings_search_gin` then filter/sort; **at most 1000 candidate matches** are ranked, then paged |
| absent | present | `-created_at`, `price_minor`, `-price_minor` | `listings_browse_new_idx` / `listings_browse_price_idx` |
| absent | absent | `-created_at` | newest feed, bounded by `limit` + cursor |

`sort=price_minor` without a category, or with `q`, → **422 `unsupported_combination`**.

**200 OK**

```json
{
  "data": [
    { "id": "0190a000-0000-7000-8004-000000000001", "title": "Handwoven Kente cloth, blue and gold",
      "price": { "amount_minor": 4500000, "currency": "NGN" }, "category_id": "0190a000-…",
      "seller": { "id": "0190a000-…", "shop_name": "Kente Cloth Co", "shop_slug": "kente-cloth-co" },
      "rating": { "count": 1, "sum": 5 }, "in_stock": true, "created_at": "2026-10-24T21:31:36Z" }
  ],
  "page": { "limit": 20, "next_cursor": "eyJzIjoicmVsZXZhbmNlIiwiayI6WzAuMDk5LCIwMTkw…", "has_more": true }
}
```

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_cursor` | tampered, expired, or used with different filters/sort |
| 422 | `validation_failed` | `limit` out of 1..100, `q` too long, non-integer price bound, `min > max` |
| 422 | `currency_required` | a price bound without `currency` |
| 422 | `unsupported_sort` | sort value not in the list |
| 422 | `unsupported_combination` | e.g. `price_minor` sort without `category_id` |

**Idem:** yes (read). Cache: `Cache-Control: private, max-age=15`.

---

# A3: Buyer places an order

## `POST /v1/orders`

Auth: any user. **Idem:** requires `Idempotency-Key`. This is the call a flaky mobile network will repeat; the same key returns the same order and **does not reserve stock twice**.

One DB transaction: insert the order → insert the items **sorted by `listing_id`** (a consistent lock order, so two concurrent checkouts that touch the same two listings cannot deadlock) → triggers snapshot price/title/address/fee, reserve stock, compute subtotal, write the first `order_events` row. Any failure rolls everything back, including the stock reservations.

| Field | Type | | Rule |
|---|---|---|---|
| shipping_address_id | uuid | R | one of the caller's live addresses |
| items | array | R | 1 to 50 lines, **all from one seller** |
| items[].listing_id | uuid | R | unique within the array |
| items[].quantity | integer | R | 1 to 999 |
| items[].expected_unit_price | Money | R | the price the buyer saw. If the live price differs the order is **refused**, never silently repriced |

```json
{ "shipping_address_id": "0190a000-0000-7000-8002-000000000003",
  "items": [ { "listing_id": "0190a000-0000-7000-8004-000000000004", "quantity": 2,
               "expected_unit_price": { "amount_minor": 350000, "currency": "NGN" } } ] }
```

**201 Created**, `Location: /v1/orders/{id}`, body `Order` with `status: "pending_payment"`; `items_subtotal` and `total` are authoritative; the buyer pays `total` within 30 minutes.

| Status | `code` | When |
|---|---|---|
| 400 | `idempotency_key_required` | header missing |
| 403 | `cannot_buy_own_listing` | the seller's own user is the buyer (`DK003`) |
| 404 | `listing_not_found` | a listing id does not exist, is deleted, or is a draft (existence of drafts is not revealed) |
| 404 | `address_not_found` | not the caller's / deleted |
| 409 | `out_of_stock` | `meta`: `listing_id`, `available`. The whole order fails; nothing is reserved |
| 409 | `listing_unavailable` | listing is `paused` or its shop is suspended |
| 409 | `price_changed` | `meta`: `listing_id`, `current_unit_price`. Client re-shows the price |
| 409 | `idempotency_in_progress` | same key still running |
| 422 | `validation_failed` | empty/oversized `items`, duplicate listing, quantity range, non-integer money |
| 422 | `multiple_sellers_or_currencies` | items belong to more than one shop |
| 422 | `idempotency_key_reuse` | same key, different body |

**Why 409 and not 422 for stock/price:** the request is well-formed; it conflicts with the *current state of the world*, and retrying later may succeed.

---

# A4: Buyer pays

Payment is two calls: the buyer **starts** a payment (we create the row and ask the provider for a payment session), and later the **provider tells us** it was captured. The order becomes `paid` only from the second, never from the client's word.

## `POST /v1/orders/{id}/payments`: start a payment attempt

Auth: the order's buyer. **Idem:** requires `Idempotency-Key`. A different key while an attempt is live is a *new* request and gets 409 `payment_in_progress` (enforced by `payments_one_live_per_order`), which is the double-charge protection.

The **amount is never taken from the client**; it is the order's `total`.

| Field | Type | | Rule |
|---|---|---|---|
| provider | string | R | `paystack` (enum, extensible) |
| return_url | string | O | https URL the provider sends the buyer back to |

**201 Created**

```json
{ "payment": { "id": "0190a000-…", "order_id": "0190a000-…", "status": "pending",
               "amount": { "amount_minor": 3000000, "currency": "NGN" }, "provider": "paystack",
               "failure_code": null, "created_at": "2026-10-24T21:35:00Z" },
  "client_action": { "type": "redirect", "url": "https://checkout.paystack.example/abc123" } }
```

| Status | `code` | When |
|---|---|---|
| 400 | `idempotency_key_required` | header missing |
| 404 | `not_found` | order not yours |
| 409 | `order_not_payable` | status is not `pending_payment` (cancelled, expired, already paid). `meta.status` says which |
| 409 | `payment_in_progress` | a `pending`/`authorized`/`captured` payment exists. `meta.payment_id` returned so the client resumes it |
| 409 | `idempotency_in_progress` | same key still running |
| 422 | `validation_failed` | unknown provider, bad return URL |
| 422 | `idempotency_key_reuse` | same key, different body |
| 502 | `provider_unavailable` | provider call failed. The attempt row is marked `failed` (`failure_code: provider_unavailable`) so the buyer can retry with a **new** key |

## `POST /v1/webhooks/payments/{provider}`: provider → us

Auth: **no bearer token**; authenticity is the provider's HMAC signature in `X-Signature` over the raw body. Called by the provider, retried by the provider for days.

Behaviour, in one transaction:
1. Verify the signature and parse. Insert into `payment_events` with the provider's event id as primary key. **A duplicate id means "already processed": return 200 and do nothing.**
2. Find the payment by `(provider, provider_reference)`.
3. Apply the transition (`pending→authorized|captured|failed`, `authorized→captured|voided`, `captured→refunded`). An illegal or out-of-order transition is ignored and logged (providers deliver out of order), still 200.
4. If it became `captured` **and the order is `pending_payment`**: set the order `paid`.
5. If it became `captured` and the order is **not** `pending_payment` (e.g., it expired and was cancelled): the payment is stored as captured and left for the refund reconciliation job. **The order is not resurrected** (`cancelled → paid` is forbidden).

**Idem:** yes, by event id.

| Status | `code` | When |
|---|---|---|
| 200 | n/a | processed, duplicate, or ignored out-of-order |
| 202 | n/a | unknown payment reference. Acknowledged so the provider stops retrying; an alert is raised |
| 400 | `malformed_request` | unparsable body |
| 401 | `invalid_signature` | signature fails (no body details returned) |
| 404 | `unknown_provider` | provider not configured |

---

# A5: Seller works the queue and ships

## `GET /v1/sellers/me/orders`: seller's orders (the fulfilment queue)

Auth: seller. Only the caller's own shop's orders.

| Param | Type | Rule |
|---|---|---|
| `status` | enum list | any of the order statuses, comma-separated. **The fulfilment queue is `status=paid`.** |
| `created_from`, `created_to` | timestamp | range on `created_at` |
| `sort` | enum | `created_at` (oldest first; **default when `status=paid`**), `-created_at` (default otherwise) |
| `limit`, `cursor` | | standard |

Indexes: `status=paid` → `orders_fulfilment_queue_idx`; otherwise `orders_seller_history_idx`. A multi-status filter that includes `paid` is served by the history index (the queue index only exists for the pure queue). `sort=created_at` (ascending) with a status other than `paid` → 422 `unsupported_combination`.

**200 OK**: `data` is `OrderSummary[]` plus, for sellers, `ship_to.city` and `item_count` so the queue screen needs no second call:

```json
{ "data": [ { "id": "0190a000-…", "order_number": "DK-2C35ABD40B11", "status": "paid",
              "seller": { "id": "0190a000-…", "shop_name": "Lagos Gadgets" },
              "total": { "amount_minor": 13400000, "currency": "NGN" }, "item_count": 2,
              "ship_to_city": "Lagos", "created_at": "2026-10-24T21:31:36Z" } ],
  "page": { "limit": 20, "next_cursor": null, "has_more": false } }
```

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_cursor` | |
| 403 | `not_a_seller` | |
| 422 | `validation_failed` | bad status value, `limit` range, `from > to` |
| 422 | `unsupported_combination` | see above |

## `POST /v1/orders/{id}/ship`: paid → shipped

Auth: the seller of this order. **Idem:** by state (below).

| Field | Type | | Rule |
|---|---|---|---|
| carrier | string | R | 1 to 60 chars |
| tracking_number | string | R | 1 to 60 chars |

**200 OK** body `Order` with `status: "shipped"`, `shipment` filled, `timestamps.shipped_at` set by the server.

| Status | `code` | When |
|---|---|---|
| 403 | `not_a_seller` | |
| 404 | `not_found` | order is not this shop's |
| 409 | `invalid_state_transition` | order is not `paid` (cancelled, pending, already delivered…). `meta.from` |
| 409 | `already_shipped` | order is `shipped` with a **different** carrier/tracking. (Same values → 200, idempotent) |
| 422 | `validation_failed` | missing/oversized fields |

---

# Users

| Endpoint | Auth | Request | Success | Errors (beyond E-STD) | Idem |
|---|---|---|---|---|---|
| `POST /v1/users` | token from IdP, no profile yet | `email` R, `full_name` R (1..120), `phone_e164` O | **201** `{ id, email, full_name, phone_e164, created_at }` | 400 `idempotency_key_required`; 409 `email_taken`, `idempotency_in_progress`; 422 `validation_failed`, `idempotency_key_reuse` | key |
| `GET /v1/users/me` | user | n/a | **200** same shape + `is_seller` | 404 `not_found` (erased) | yes |
| `PATCH /v1/users/me` | user | any of `full_name`, `phone_e164` (email change goes through the IdP) | **200** user | 409 `email_taken`; 422 `validation_failed` | yes (absolute values) |
| `DELETE /v1/users/me` | user | n/a | **204**. Calls `anonymise_user()` | 409 `open_orders`: order in `pending_payment/paid/shipped/delivered` as buyer or seller (`meta.order_ids` ≤ 20); repeating after success: **204** | yes |

# Addresses

| Endpoint | Request | Success | Errors | Idem |
|---|---|---|---|---|
| `POST /v1/users/me/addresses` | `recipient_name`, `line1`, `city`, `postal_code`, `country` R; `line2`, `region`, `phone_e164`, `is_default` O | **201** `Address`. Making it default clears the previous default in the same transaction | 400 `idempotency_key_required`; 409 `idempotency_in_progress`; 422 `validation_failed`, `idempotency_key_reuse`; 422 `address_limit` (max 20) | key |
| `GET /v1/users/me/addresses` | list. Filter: none. Sort: `-created_at` fixed. Standard page envelope | **200** `Address[]` | n/a | yes |
| `GET /v1/users/me/addresses/{id}` | n/a | **200** | 404 `not_found` | yes |
| `PATCH /v1/users/me/addresses/{id}` | any address field | **200** | 404 `not_found`; 422 `validation_failed`. Editing never alters existing orders (they hold a snapshot) | yes |
| `DELETE /v1/users/me/addresses/{id}` | n/a | **204** soft delete | 404 `not_found` (never existed / not yours); already deleted → 204 | yes |

# Sellers

| Endpoint | Auth | Request | Success | Errors | Idem |
|---|---|---|---|---|---|
| `POST /v1/sellers` | user | `shop_name` R (2..80), `shop_slug` R (`^[a-z0-9]+(-[a-z0-9]+)*$`), `currency` R (ISO), `flat_shipping_fee` O Money (default 0) | **201** `{ id, shop_name, shop_slug, currency, flat_shipping_fee, status: "pending_review" }` | 400 `idempotency_key_required`; 409 `shop_exists`, `slug_taken`, `idempotency_in_progress`; 422 `validation_failed`, `idempotency_key_reuse` | key |
| `GET /v1/sellers/me` | seller | n/a | **200** shop + `status` | 403 `not_a_seller` | yes |
| `PATCH /v1/sellers/me` | seller | `shop_name`, `flat_shipping_fee` (`currency` is immutable → 422 `immutable_field`) | **200**. Existing orders keep their snapshotted fee/name | 403 `not_a_seller`; 409 `slug_taken` (if slug is editable later); 422 | yes |
| `GET /v1/sellers/{id}` | any | n/a | **200** public view `{ id, shop_name, shop_slug, rating: {count,sum} }` | 404 `not_found` (also for suspended/closed) | yes |
| `GET /v1/sellers/me/listings` | seller | filters `status` (list), `sort` ∈ {`-created_at`}, standard page | **200** page of `Listing` (with `stock_quantity`) | 403 `not_a_seller`; 422 | yes |

# Categories

| Endpoint | Auth | Request | Success | Errors | Idem |
|---|---|---|---|---|---|
| `GET /v1/categories` | any | `parent_id` filter (O; omit = roots); `sort` fixed `name`; standard page | **200** `{ id, parent_id, name, slug }[]` | 422 `validation_failed` | yes (cache `max-age=3600`) |
| `POST /v1/staff/categories` | staff | `name`, `slug` R; `parent_id` O | **201** | 403 `forbidden`; 404 `parent_not_found`; 409 `slug_taken`; 422 | key |

# Listings: other operations

| Endpoint | Auth | Request | Success | Errors | Idem |
|---|---|---|---|---|---|
| `GET /v1/listings/{id}` | any | n/a | **200** `Listing` (`stock_quantity` only to the owner; others get `in_stock`). Drafts only to owner | 404 `not_found` (draft of someone else, deleted, or nonexistent) | yes |
| `PATCH /v1/listings/{id}` | owner | any of `title`, `description`, `category_id`, `price` (same currency), `stock_quantity` | **200** `Listing`. Price/title changes **never** affect existing orders | 404 `not_found`; 409 `resource_frozen`; 422 `validation_failed`, `currency_mismatch` | yes |
| `POST /v1/listings/{id}/pause` | owner | n/a | **200** | 404; 409 `invalid_state_transition` (draft→paused is forbidden, `meta.from=draft`); already paused → 200 | state |
| `POST /v1/listings/{id}/resume` | owner | n/a | **200** | 403 `seller_not_active`; 404; 409 `invalid_state_transition` (from `draft`); already active → 200 | state |
| `DELETE /v1/listings/{id}` | owner | n/a | **204** soft delete (history keeps it) | 404 `not_found`; already deleted → 204 | yes |
| `GET /v1/listings/{id}/reviews` | any | `rating` filter (1..5, list); `sort` ∈ {`-created_at`}; standard page | **200** `Review[]` | 404 `not_found`; 422 | yes |

# Orders: other operations

| Endpoint | Auth | Request | Success | Errors | Idem |
|---|---|---|---|---|---|
| `GET /v1/orders` | buyer | filters: `status` (list), `created_from`, `created_to`; `sort` ∈ {`-created_at` default, `created_at`}; standard page | **200** `OrderSummary[]` | 400 `invalid_cursor`; 422 `validation_failed` | yes. Index: `orders_buyer_history_idx` |
| `GET /v1/orders/{id}` | the buyer **or** the order's seller or staff | n/a | **200** `Order`. A seller does not see `payment` details beyond `status` | 404 `not_found` | yes |
| `GET /v1/orders/{id}/events` | buyer / seller / staff | `limit`, `cursor`; sort fixed `created_at` asc | **200** `{ id, from_status, to_status, actor_type, created_at }[]` | 404 | yes |
| `POST /v1/orders/{id}/cancel` | buyer (while `pending_payment` or `paid`), seller (while `paid`) | `reason` O (≤ 200) | **200** `Order` `cancelled`; stock restored by trigger; if a captured payment exists a refund job is queued (`meta.refund_queued`) | 404; 409 `invalid_state_transition` (`shipped`, `delivered`, `completed`, `refunded`, and `meta.from` says which) | state; cancelling a cancelled order → 200 |
| `POST /v1/orders/{id}/confirm-receipt` | buyer | n/a | **200** `Order` `completed` | 404; 409 `invalid_state_transition` (not `delivered`) | state |
| `POST /v1/orders/{id}/deliver` | system (carrier webhook) or staff | `delivered_at` O | **200** `Order` `delivered` | 403 `forbidden`; 404; 409 `invalid_state_transition` (not `shipped`) | state |
| `POST /v1/staff/orders/{id}/refund` | staff | `reason` R | **200** `Order` `refunded`; payment moved to `refunded` first | 403; 404; 409 `invalid_state_transition` (not `delivered`; **a `completed` order cannot be refunded**); 409 `payment_not_refunded` (`DK003`) | state |

An unpaid order is expired by a job (`orders_pending_expiry_idx`, 30 min) which performs the same `pending_payment → cancelled` transition with `cancelled_by = system`.

# Payments (reads)

| Endpoint | Auth | Request | Success | Errors | Idem |
|---|---|---|---|---|---|
| `GET /v1/orders/{id}/payments` | buyer / staff | `sort` fixed `created_at` asc; standard page | **200** `Payment[]` (all attempts) | 404 | yes. Index: `payments_order_idx` |
| `GET /v1/payments/{id}` | buyer / staff | n/a | **200** `Payment` | 404 | yes |

# Reviews

| Endpoint | Auth | Request | Success | Errors | Idem |
|---|---|---|---|---|---|
| `POST /v1/reviews` | buyer | `order_item_id` R (uuid), `rating` R (integer 1..5), `body` O (≤ 2000) | **201** `Review`. The aggregate on the listing is updated by trigger | 400 `idempotency_key_required`; 404 `not_found` (item not in your order); **409 `order_not_completed`** (FK `reviews_order_completed_fk`); 409 `already_reviewed`; 409 `idempotency_in_progress`; 422 `validation_failed`, `idempotency_key_reuse` | key |
| `GET /v1/reviews/{id}` | any | n/a | **200** | 404 | yes |
| `PATCH /v1/reviews/{id}` | author | `body` only (rating is immutable → 422 `immutable_field`) | **200** | 404; 422 | yes |
| `DELETE /v1/staff/reviews/{id}` | staff | `reason` R | **204** soft delete; aggregate decremented | 403; 404; already deleted → 204 | yes |

# Staff

| Endpoint | Request | Success | Errors | Idem |
|---|---|---|---|---|
| `PATCH /v1/staff/sellers/{id}` | `status` ∈ {`active`, `suspended`} | **200** seller. Suspension pauses the shop's active listings in the same transaction (`active → paused`, so search needs no join to `sellers`) and blocks new orders (`DK003`) | 403 `forbidden`; 404; 422 `validation_failed` | yes |
