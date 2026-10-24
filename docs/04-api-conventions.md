# 4a. API conventions (apply to every endpoint)

Endpoint contracts are in [04-api-contracts.md](04-api-contracts.md). Nothing in the contracts repeats what is defined here, so an implementer reads this file once.

## Basics

| Topic | Rule |
|---|---|
| Base URL | `https://api.duka.example/v1` |
| Versioning | Major version in the path (`/v1`). Additive changes (new optional field, new endpoint, new enum value in a *response*) are not breaking and do not bump the version. Removing/renaming a field, tightening validation or changing semantics ships as `/v2`; `/v1` is supported for 12 months after. Clients must ignore unknown response fields. |
| Format | JSON, UTF-8. Requests: `Content-Type: application/json` (else **415**). Field names `snake_case`. |
| Auth | `Authorization: Bearer <JWT>` from the identity provider. `sub` = user id; claim `roles` ⊆ {`staff`}; *buyer* and *seller* are derived from the DB (a user is a seller iff they have a `sellers` row). |
| Ids | UUID strings. Order references additionally have `order_number` (`DK-` + 12 hex), display only, never used as a path parameter. |
| Timestamps | ISO-8601 UTC, `2026-10-24T21:31:36Z`. |
| Money | Always `{"amount_minor": 4500000, "currency": "NGN"}`. `amount_minor` is a JSON **integer**; a decimal or string is a 422. Whole numbers of minor units only. |
| Ownership | A resource owned by someone else returns **404**, not 403, so existence is not leaked. 403 is reserved for "I know who you are and this *role* may not do this" (e.g., a buyer calling a staff endpoint). |
| Request id | Every response carries `X-Request-Id`; it is also in every error body. |
| Rate limits | `429` with `Retry-After` (seconds) and `RateLimit-Limit/Remaining/Reset`. Default 120 req/min/user, 20 req/min on unauthenticated endpoints. |

## Errors (RFC 9457 `application/problem+json`)

```json
{
  "type": "https://api.duka.example/problems/out_of_stock",
  "title": "Not enough stock",
  "status": 409,
  "code": "out_of_stock",
  "detail": "Listing 0190a000-… has 2 in stock; 3 requested.",
  "request_id": "req_01HV…",
  "errors": [ { "field": "items[0].quantity", "code": "exceeds_stock", "message": "max 2" } ],
  "meta": { "listing_id": "0190a000-…", "available": 2 }
}
```

`code` is the stable, machine-readable value clients switch on. `title`/`detail` are for humans and may change. `errors[]` appears on 422 only. `meta` carries code-specific data.

### Standard errors (E-STD)

Every endpoint can return these. They are **not** repeated in each contract except where they have a special meaning.

| Status | `code` | When |
|---|---|---|
| 400 | `malformed_request` | body is not valid JSON, wrong content type charset, unknown query parameter, bad uuid in a path |
| 401 | `unauthenticated` | missing, expired or invalid token |
| 415 | `unsupported_media_type` | body present but not `application/json` |
| 429 | `rate_limited` | over the limit |
| 500 | `internal_error` | unexpected; safe to retry **only** with an `Idempotency-Key` |
| 503 | `service_unavailable` | overloaded or in maintenance; `Retry-After` set |

Each contract lists, **additionally**, its own 400/403/404/409/422 errors. A contract's error table is therefore *complete* when read together with E-STD.

### Database error → API error mapping

Handlers pre-check the common cases to give good messages, but the database is the authority; a violated constraint is translated, never leaked:

| DB signal | API response |
|---|---|
| `23514` `listings_stock_nonneg` | 409 `out_of_stock` |
| `23514` other CHECK | 422 `validation_failed` |
| `23505` `users_email_live_uq` | 409 `email_taken` |
| `23505` `sellers_user_id_key` | 409 `shop_exists` |
| `23505` `sellers_slug_live_uq` | 409 `slug_taken` |
| `23505` `payments_one_live_per_order` | 409 `payment_in_progress` |
| `23505` `reviews_one_per_item` | 409 `already_reviewed` |
| `23505` `orders_order_number_key` | internal retry with a new number (never surfaced) |
| `23503` `reviews_order_completed_fk` | 409 `order_not_completed` |
| `23503` `orders_ship_address_belongs_to_buyer` | 422 `validation_failed` on `shipping_address_id` |
| `23503` `order_items_order_fk` | 422 `multiple_sellers_or_currencies` |
| `DK001` | 409 `invalid_state_transition` (`meta.from`, `meta.to`) |
| `DK002` | 409 `resource_frozen` |
| `DK003` | 422 `business_rule_violated` (`meta.rule`) |

## Idempotency

**Idempotent by HTTP semantics:** `GET`, `PUT`, `DELETE`, and `PATCH` (every PATCH here sets absolute values, never "increment").

**Create/charge POSTs require `Idempotency-Key`** (8 to 128 chars, a client-generated UUID is typical). They are: `POST /users`, `/sellers`, `/addresses`, `/listings`, `/orders`, `/orders/{id}/payments`, `/reviews`. Missing key → **400 `idempotency_key_required`**.

Server behaviour, keyed on `(authenticated user, key)` in `idempotency_keys`, kept 24 h:

| Situation | Result |
|---|---|
| First time | Process normally. A row with `response_status = NULL` is inserted first (acts as a lock). Afterwards the status and body are stored. |
| Same key, same method+path+body hash, finished | Replay the stored status and body; header `Idempotent-Replayed: true`. No side effects. |
| Same key, still being processed | **409 `idempotency_in_progress`**, `Retry-After: 1`. |
| Same key, **different** body or path | **422 `idempotency_key_reuse`**. |
| Server crashed mid-request | The operation's own transaction either committed (and the stored response is written in the *same* transaction) or rolled back; a retry re-runs it safely. |

**State-transition commands** (`/ship`, `/cancel`, `/confirm-receipt`, …) need no key: they are idempotent *by state*. Repeating a command whose effect already holds with identical parameters returns **200 with the current representation**; repeating it with *conflicting* parameters, or from a state that forbids it, returns 409. Exactly-once effects (the trigger writes one `order_events` row per real transition) come from the state machine, not from key storage.

**Webhooks** are deduplicated by the provider's event id, which is the primary key of `payment_events`.

## Pagination, filtering, sorting (every list endpoint)

All lists use **keyset (cursor) pagination**. There is no `offset`/`page`. Offsets get slower with depth and skip or repeat rows when data changes between requests (N5).

**Request**

| Param | Type | Rule |
|---|---|---|
| `limit` | integer | 1 to 100, default 20. Outside the range → 400 (not clamped silently). |
| `cursor` | string | Opaque. Omit for page 1. Use exactly the `page.next_cursor` returned. |
| `sort` | string | One value from the endpoint's allowed list, `-` prefix = descending. Default is endpoint-specific. Not in list → 422 `unsupported_sort`. |
| filters | | Documented per endpoint. Multi-value filters are comma-separated (`status=paid,shipped`). Ranges use `_from` (inclusive) and `_to` (exclusive). Unknown parameter → 400. |

**Response envelope**

```json
{
  "data": [ { "…": "…" } ],
  "page": { "limit": 20, "next_cursor": "eyJrIjpb…", "has_more": true }
}
```

- `next_cursor` is `null` and `has_more` is `false` on the last page.
- The server fetches `limit + 1` rows to compute `has_more`; no `COUNT(*)` is run. **No total count** is returned (it costs a full scan and changes under the reader). Endpoints that genuinely need it say so.
- Every sort is **stable**: ties break on `id`, so a row is never skipped or repeated. The cursor encodes the last row's sort key and `id`, plus a hash of the filters and sort; reusing a cursor with different filters → 400 `invalid_cursor`.
- Cursors are signed and expire after 24 h (`invalid_cursor`).

## Real-time

Server-Sent Events, defined in [05-graphql-and-realtime.md](05-graphql-and-realtime.md).
