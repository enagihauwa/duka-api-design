# 5. Over-fetching and real-time

## 5.1 Over-fetching: REST vs GraphQL

### The endpoint

`GET /v1/orders/{id}` as used by the seller's **"pack this order"** screen.

The screen shows a packer: the order number, who and where to send it, and what is in the box with quantities. Nothing else. The REST resource is designed to serve *every* consumer of an order (buyer receipt, seller, staff, support), so it carries all of that.

**REST response** (real size, minified: **1,322 bytes**; file: [`examples/order_rest_response.json`](examples/order_rest_response.json)):

```json
{
  "id": "0190a000-0000-7000-8005-000000000003",
  "order_number": "DK-2C35ABD40B11",
  "status": "paid",
  "seller": { "id": "0190a000-…", "shop_name": "Lagos Gadgets" },
  "items": [
    { "id": "01a16fbe-…", "listing_id": "0190a000-…", "title": "Refurbished smartphone 128GB", "quantity": 1,
      "unit_price": { "amount_minor": 12500000, "currency": "NGN" },
      "line_total": { "amount_minor": 12500000, "currency": "NGN" } },
    { "id": "01a16fbe-…", "listing_id": "0190a000-…", "title": "Phone case, shockproof", "quantity": 2,
      "unit_price": { "amount_minor": 350000, "currency": "NGN" },
      "line_total": { "amount_minor": 700000, "currency": "NGN" } }
  ],
  "items_subtotal": { "amount_minor": 13200000, "currency": "NGN" },
  "shipping_fee":   { "amount_minor": 200000,   "currency": "NGN" },
  "total":          { "amount_minor": 13400000, "currency": "NGN" },
  "ship_to": { "recipient": "Bola Adeyemi", "line1": "12 Allen Avenue", "line2": null, "city": "Lagos",
               "region": "LA", "postal_code": "100001", "country": "NG" },
  "shipment": { "carrier": null, "tracking_number": null },
  "payment": { "id": "0190a000-…", "status": "captured" },
  "timestamps": { "created_at": "…", "paid_at": "…", "shipped_at": null, "delivered_at": null,
                  "completed_at": null, "cancelled_at": null },
  "cancelled_by": null
}
```

**What the screen uses:** `order_number`, `ship_to.recipient/line1/city`, and for each item `title` and `quantity`. That is roughly 12 of ~60 fields.

**The same need in GraphQL:**

```graphql
query PackScreen($id: ID!) {
  order(id: $id) {
    orderNumber
    shipTo { recipient line1 city }
    items { title quantity }
  }
}
```

**Response (243 bytes minified)**, [`examples/order_graphql_response.json`](examples/order_graphql_response.json):

```json
{ "data": { "order": {
    "orderNumber": "DK-2C35ABD40B11",
    "shipTo": { "recipient": "Bola Adeyemi", "line1": "12 Allen Avenue", "city": "Lagos" },
    "items": [ { "title": "Refurbished smartphone 128GB", "quantity": 1 },
              { "title": "Phone case, shockproof", "quantity": 2 } ] } } }
```

### Honest accounting

| | REST | GraphQL |
|---|---|---|
| Bytes for one order | 1,322 | 243 (≈ 5.4× smaller) |
| Absolute saving | **≈ 1 KB** per order | |
| A packer opens 20 orders in a session | 20 calls, ≈ 26 KB | 1 query with 20 ids, ≈ 5 KB |
| Server work | one indexed read of order + items | same reads, plus a resolver layer, query-cost limiting, N+1 protection (DataLoader) |

**One kilobyte is not a problem.** gzip and HTTP/2 make it invisible on any real connection. I measured a 5× ratio and I will not pretend that 5× of a tiny number is a crisis. The *shape* mismatch is real; the *cost* is not, yet.

### Would I use GraphQL here? **No, not for the MVP.**

REST is the right default for an MVP: it is cacheable by URL, trivially observable (one route = one metric = one rate limit), every engineer already knows it, the DB-to-resource mapping is direct (the idempotency, error and pagination contracts in this document all assume resource semantics), and with two clients (buyer app, seller web) whose screens are all within a few fields of the resource, GraphQL buys little while adding a second contract to design, secure (query depth, cost limits, field-level auth), and operate.

**Cheap REST fixes first**, in this order:
1. `?fields=order_number,ship_to,items(title,quantity)` sparse fieldsets on the 3 heaviest resources.
2. `?expand=items` on list endpoints (kills the N+1 round-trips, which cost far more than the extra bytes).
3. A purpose-built read model such as `GET /v1/sellers/me/pack-list` if one screen dominates.

### When I would switch, and what triggers it

User count is a poor trigger: 100 k users on one app is fine on REST; 5 k users on four different clients may not be. I would switch an *area* (not the whole API) to GraphQL when **two or more** of these are observed, with numbers:

1. **Three or more distinct client surfaces** (buyer app, seller dashboard, staff console, partner integrations) whose screens need materially different slices of the same graph, evidenced by a growing list of one-off endpoints and `?fields` variants.
2. **Request waterfalls:** a primary screen needs **≥ 3 sequential REST calls** (e.g., listing → seller → reviews → "more from this shop") and measured p75 time-to-interactive on mobile misses its budget because of round trips.
3. **Payload cost shows up in measurement:** p75 response size on a primary mobile screen over **~100 KB** or an egress bill line attributable to over-fetching.
4. **Backend change tax:** frontend teams file more than a few "add this field to endpoint X" tickets per sprint.

At the scale I would *expect* those to appear, a rough guide is **a six-figure monthly active user count with at least three client teams**, but the triggers above, not the headcount, make the decision. The first GraphQL field I would add is the buyer's listing-detail page (item + seller + reviews summary), which is the real waterfall in this product. The database model does not change either way; GraphQL is another reader of the same tables.

---

## 5.2 Real-time: where polling would hurt

**The case:** a seller sitting on the fulfilment queue wants a *new paid order* to appear without refreshing; a buyer on the order page wants to see `paid → shipped → delivered` change live. (F5, N4.) Polling `GET /orders/{id}` every 5 s from every open page is wasteful, and it still lags.

### Choice: **Server-Sent Events (SSE)**, not WebSockets

The deciding fact is **direction**. WebSockets are *bidirectional*: both sides push frames on one connection. SSE is *unidirectional*: the server streams to the client over a plain HTTP response. Here the data flows one way only; the client's actions ("ship this", "cancel") are ordinary request/response calls with the idempotency and error contracts already defined. Nothing needs to travel up the live connection.

| | SSE (chosen) | WebSocket |
|---|---|---|
| Direction | server → client | both |
| Transport | normal HTTP; works through proxies, CDNs, HTTP/2 multiplexing | upgraded protocol; needs sticky/upgrade-aware infrastructure |
| Reconnect and missed events | **built in**: the browser reconnects and sends `Last-Event-ID` | you build it |
| Auth, rate limiting, logging | same middleware as every other route | separate handshake and message-level auth |
| Binary frames, client→server stream | no | yes |

**Where I would switch to WebSockets:** a feature where the client *sends a stream* back on the same channel, i.e. live buyer↔seller **chat** with typing indicators, or a live **auction** with bids. Then both directions are genuinely live and the extra machinery pays. Not before.

### Contract

`GET /v1/orders/{id}/stream` (buyer, order's seller, staff) → `Content-Type: text/event-stream`.

```
id: 01a16fbe-6565-7f33-be5a-14790b5faa07
event: order.status_changed
data: {"order_id":"0190a000-…","from":"paid","to":"shipped","at":"2026-10-24T21:40:12Z"}

: ping            ← comment heartbeat every 25 s so proxies keep the socket open
```

- **Event id = `order_events.id`.** Because ids are UUIDv7 (time-ordered), `Last-Event-ID` resume is `SELECT … FROM order_events WHERE order_id = $1 AND (created_at, id) > (…) ORDER BY created_at, id`, served by `order_events_order_idx`. A client that was offline for a minute misses nothing.
- First event after connect is `order.snapshot` with the current `Order`, so a client needs no separate GET.
- Errors are normal HTTP **before** the stream starts: 401, 404 `not_found`, 429 (limit **5 concurrent streams per user**). After the stream starts, the server ends it with `event: error` + `retry:` and the client reconnects.
- `GET /v1/sellers/me/orders/stream` (seller) emits `order.paid` **hints** (`{order_id, order_number}`) and **has no replay**: after a reconnect the client simply re-fetches the queue (`GET /v1/sellers/me/orders?status=paid`), which is already an indexed query. This avoids an index on events by seller for a rarely needed replay.
- Native browser `EventSource` cannot set an `Authorization` header, so web clients use a `fetch`-based SSE reader (or a short-lived single-use `?ticket=` from `POST /v1/stream-tickets`).

### Fan-out

The source of truth is the `order_events` table, written by the order trigger in the same transaction as the status change, so an event exists **if and only if** the change committed. API instances listen for a `NOTIFY` of the new event id (Postgres `LISTEN/NOTIFY` is enough for one region; a Redis pub/sub channel replaces it past a few thousand concurrent streams). The `NOTIFY` emission is a design note: the proof in this repo covers the table, trigger and indexes, not the listener process.
