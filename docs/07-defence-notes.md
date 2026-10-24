# 7. Defence notes

The brief's defence questions are written for ride-hailing (rider, trip, fare). The marketplace equivalents are given first; the literal question is answered where it maps cleanly.

## "Show me a fact that lives in two places and defend it."

**`order_items.unit_price_minor` and `listings.price_minor`.**

They look like one fact, but they are two: *what the item costs now* and *what this buyer agreed to pay*. They agree on the day of purchase and diverge the moment the seller edits the price. If an order read the price from the listing, then (1) the buyer's receipt would change after the fact, (2) the amount already charged would no longer match the order, and (3) a refund would be computed from the wrong number. The copy is written once, by the database (`order_items_guard()` overwrites whatever the client sent), and the line is immutable afterwards (`DK002`, demonstrated as invalid insert 14). It cannot drift because it never changes.

*Second example, if pushed:* `orders.ship_*`, a copy of **personal data**. It exists because the parcel must go where the order said even if the address is edited later; it is made safe by being scrubbed by `anonymise_user()` and nothing else (§3.1 D2).

*What I would not defend:* `listings.rating_sum/count`. That is a *cache*, not a fact in two places. I defend it only because a trigger and a CHECK keep it equal to the reviews, and the bulk audit shows 0 mismatches over 72k reviews.

## "A rider requests a second trip while one is in progress. Which line in your schema stops it?"

The marketplace has no "one active order per buyer" rule, and I did not invent one (F1-F10 don't need it). The two equivalent *money-safety* rules it does have:

- **A second live payment for the same order** (the double-charge): `CREATE UNIQUE INDEX payments_one_live_per_order ON payments (order_id) WHERE status IN ('pending','authorized','captured');` Demonstrated as invalid insert 7: `ERROR: 23505 duplicate key value violates unique constraint "payments_one_live_per_order"`.
- **Two buyers taking the last unit concurrently:** `CONSTRAINT listings_stock_nonneg CHECK (stock_quantity >= 0)`, with the reserve `UPDATE` in `order_items_after_insert()`. The first `UPDATE` takes the row lock; the second waits, sees the new stock, drives it to −1 and fails. Demonstrated as required rejection 1. No application-level check, which would race, is involved.

In the ride-hailing version the line would be: `CREATE UNIQUE INDEX one_active_trip_per_rider ON trips (rider_id) WHERE status IN ('requested','accepted','arrived','in_progress');`. Same technique, a partial unique index over the "live" statuses.

## "Why does the trip record store the fare rather than looking it up from the driver's current rate?"

Marketplace form: **why does the order store the price rather than looking up the listing's current price?** (and, one level up, why `orders.total_minor` is stored arithmetic of stored parts.)

Because the price is a *historical agreement*, not a property of the listing. A lookup would let a later price change rewrite past receipts, make the already-captured payment disagree with the order, and corrupt refunds and tax records. Money records must be reproducible from themselves. The same reason applies to the ride version: a fare depends on distance, time, surge and the rate card in force *at the time*; looking up the driver's *current* rate would silently reprice every past trip.

## "At what user count do you switch this endpoint to GraphQL, and what specifically would trigger it?"

**Not a user count.** I measured the over-fetch on the seller "pack this order" screen: 1,322 bytes of REST against 243 bytes for GraphQL, about 5.4×, but about 1 KB absolute, which gzip and HTTP/2 make invisible. REST remains the right choice for the MVP.

I would move *one area* (the buyer's listing-detail page first) when **two or more** of these hold, measured: (1) three or more client surfaces needing different slices of the same data; (2) a primary screen needing **≥ 3 sequential REST calls** and missing its mobile time-to-interactive budget because of round trips; (3) p75 payload on a primary mobile screen above ~100 KB, or egress cost attributable to over-fetching; (4) frontend teams repeatedly blocked on "add this field to endpoint X". As a rough guide, that combination shows up around **six-figure monthly active users with three client teams**, but the triggers decide, not the headcount. Before that, `?fields=` and `?expand=items` fix 90 % of it for almost nothing.

## Likely follow-ups

| Question | Answer |
|---|---|
| "Why not just trust the application to check transitions?" | Because there will be two apps, a script, and an on-call engineer with a SQL prompt. The table-driven trigger is the one place all of them pass. |
| "Why triggers? Isn't that hidden logic?" | Triggers hold *invariants* (snapshots, legality, stock). Policy (who may call what, pricing, search) stays in the application. The migration is the single readable place for the former. |
| "Why UUIDv7 and not v4?" | Insert locality and time-ordered keyset/resume, at the price of revealing creation time but not count or sequence (§3.5). |
| "What did bulk loading cost you?" | I had to `DISABLE TRIGGER USER` to load 300k orders; I kept FK/CHECK on and audited afterwards. That is a loader, not a code path, and the app role cannot do it. |
| "What is not modelled?" | Carts/multi-seller checkout, FX, disputes beyond `delivered→refunded`, lost parcels (`shipped→refunded`), goodwill refunds after `completed`, seller payouts. All noted where they bite. |
| "Where could this design be wrong?" | The 30-minute expiry versus slow payment providers (a long-pending provider session can capture after expiry; handled by reconciliation, not prevented). Search ranking is keyword-only; at ~1M listings or fuzzy matching needs, move to a dedicated search engine with the DB as source of truth. |
