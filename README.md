# Duka Marketplace: API design and data model (Task 3)

A multi-seller marketplace (sellers, buyers, listings, orders, payments, reviews), designed before it is built, with a PostgreSQL schema that proves the model holds.

> **Product choice.** The brief says not to pick something you have already built. A ride-hailing system (`ryde`) already exists on this machine, so this uses the other suggested product, a marketplace.

## Read in this order

| # | Document | Brief requirement |
|---|---|---|
| 1 | [docs/01-requirements.md](docs/01-requirements.md) | Requirements page, five actions, traceability |
| 2 | [docs/02-data-model.md](docs/02-data-model.md) | Entities, fields, types, identifiers, cardinalities, **ER diagram** |
| 3 | [docs/03-hard-questions.md](docs/03-hard-questions.md) | The seven hard questions: normalisation, money, state (**state machine**), time, identifiers, constraints, indexes |
| 4 | [docs/04-api-conventions.md](docs/04-api-conventions.md), [docs/04-api-contracts.md](docs/04-api-contracts.md) | Endpoint contracts: paths, bodies, responses, every error, idempotency, pagination/filter/sort |
| 5 | [docs/05-graphql-and-realtime.md](docs/05-graphql-and-realtime.md) | Over-fetching (REST vs GraphQL) and real-time (SSE vs WebSockets) |
| 6 | [docs/06-proof.md](docs/06-proof.md) | Schema proof: five queries, **query plans**, **rejected invalid inserts** |
| 7 | [docs/07-defence-notes.md](docs/07-defence-notes.md) | Answers to the four defence questions |
| 8 | [docs/POST.md](docs/POST.md) | The post: the transition I didn't know was forbidden |

## Evidence

| Evidence | Where |
|---|---|
| ER diagram | [diagrams/er.png](diagrams/er.png) (source [er.mmd](diagrams/er.mmd)) |
| State machines | [order](diagrams/order_state.png), [payment](diagrams/payment_state.png), [listing](diagrams/listing_state.png) |
| Query plans showing index use | [evidence/20_query_plans.txt](evidence/20_query_plans.txt), images `evidence/screenshots/plan_*.png` |
| Three required rejected inserts | [violation_1](evidence/screenshots/violation_1_oversell.png), [violation_2](evidence/screenshots/violation_2_review_without_completed_order.png), [violation_3](evidence/screenshots/violation_3_illegal_transition.png); raw: [evidence/30_invalid_inserts.txt](evidence/30_invalid_inserts.txt) (16 scenarios, 17 rejected statements) |
| Schema constraint/index/trigger listing | [evidence/00_schema_listing.txt](evidence/00_schema_listing.txt) |

## Run it

Needs PostgreSQL **18** (uses native `uuidv7()`) with a local superuser `postgres`, and Git Bash / any bash.

```bash
bash db/run_proof.sh                 # rebuilds database duka_task3 and regenerates evidence/*.txt (about 1 minute)
python tools/render_evidence.py      # optional: renders evidence excerpts to PNG (needs Chrome)
```

Layout: `db/migrations` (up + down), `db/seed` (small + bulk + power seller), `db/proof` (the SQL that produces each piece of evidence).

## Limits, stated plainly

- The API is a **design**; only the schema is implemented, as the brief asks. No endpoint has been run.
- The screenshots are renders of captured `psql` output, not live terminal captures (see docs/06-proof.md).
- Concurrency (two buyers, last unit) is argued from row locking and proven for the *constraint*, not load-tested with parallel sessions.
- Timings in the plans vary run to run; the plan node types and the ratios are the stable part.
