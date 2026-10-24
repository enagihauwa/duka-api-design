#!/usr/bin/env bash
# Rebuilds the database from nothing and regenerates every file in ../evidence.
# Usage:  bash db/run_proof.sh            (expects a local PostgreSQL 18, superuser "postgres")
set -euo pipefail
cd "$(dirname "$0")"
export PGUSER="${PGUSER:-postgres}" PGHOST="${PGHOST:-localhost}" PGOPTIONS='-c client_min_messages=warning'
DB=duka_task3
EV=../evidence
mkdir -p "$EV"

psql -d postgres -qc "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
run() { psql -d "$DB" -X "$@"; }

echo ">> migration up";      run -q -v ON_ERROR_STOP=1 -f migrations/001_init.up.sql
echo ">> schema listing";    run -f proof/00_schema_listing.sql                > "$EV/00_schema_listing.txt"
echo ">> small seed";        run -q -v ON_ERROR_STOP=1 -f seed/001_seed_small.sql > /dev/null
echo ">> bulk seed";         run -q -f seed/002_bulk_for_plans.sql              > "$EV/02_bulk_seed.txt" 2>&1
echo ">> power seller";      run -q -v ON_ERROR_STOP=1 -f seed/003_power_seller.sql > "$EV/03_power_seller.txt" 2>&1
echo ">> five actions";      run -q -f proof/10_five_actions.sql               > "$EV/10_five_actions.txt" 2>&1
echo ">> query plans";       run -q -f proof/20_query_plans.sql                > "$EV/20_query_plans.txt" 2>&1
echo ">> invalid inserts";   run -q -f proof/30_invalid_inserts.sql            > "$EV/30_invalid_inserts.txt" 2>&1
echo ">> late capture";      run -q -f proof/50_late_capture.sql                > "$EV/50_late_capture.txt" 2>&1
echo ">> erasure";           run -q -f proof/40_erasure.sql                    > "$EV/40_erasure.txt" 2>&1
echo ">> migration down/up round trip"
run -q -v ON_ERROR_STOP=1 -f migrations/001_init.down.sql
run -Atc "select count(*) from pg_tables where schemaname='public'" | sed 's/^/tables after down: /'
run -q -v ON_ERROR_STOP=1 -f migrations/001_init.up.sql
run -Atc "select count(*) from pg_tables where schemaname='public'" | sed 's/^/tables after re-up: /'
echo "done. Evidence written to evidence/"
