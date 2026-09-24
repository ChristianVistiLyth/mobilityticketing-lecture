#!/bin/sh
# The whole lecture 4 exercise in order, on a freshly reset database. Step labels
# match the sections of docs/evidence/lecture04/README.md. Expected failures must
# fail with the SQLSTATE given, and anything unexpected stops the run with exit code 1.
# Deletes the database volume first and leaves the database at migration 032.
#
#   sh database/postgres/experiments/lecture04/run_lab.sh
set -u
cd "$(dirname "$0")/../../../.."
dir=database/postgres/experiments/lecture04
migrations=database/postgres/migrations

fail() {
    echo "UNEXPECTED: $1"
    exit 1
}

sql() {
    docker compose exec -T postgres psql -U mobility -d mobility -v ON_ERROR_STOP=1 "$@"
}

# Standard input must fail with SQLSTATE $1. Further arguments go to psql.
sql_must_fail() {
    expected=$1
    shift
    output=$(docker compose exec -T postgres psql -U mobility -d mobility -v ON_ERROR_STOP=1 -v VERBOSITY=verbose "$@" 2>&1)
    status=$?
    printf '%s\n' "$output" | grep -v '^LOCATION:'
    [ "$status" -ne 0 ] || { echo "(succeeded, expected SQLSTATE $expected)"; return 1; }
    printf '%s\n' "$output" | grep -q "^ERROR:  $expected:" || { echo "(wrong error, expected SQLSTATE $expected)"; return 1; }
    echo "(rejected with SQLSTATE $expected, as expected)"
}

# Standard input runs to the end and must report every SQLSTATE given.
sql_with_errors() {
    output=$(docker compose exec -T postgres psql -U mobility -d mobility -v VERBOSITY=verbose 2>&1)
    printf '%s\n' "$output" | grep -v '^LOCATION:'
    for code in "$@"; do
        printf '%s\n' "$output" | grep -q "^ERROR:  $code:" || { echo "(missing expected SQLSTATE $code)"; return 1; }
    done
    echo "(expected errors seen: $*)"
}

step() {
    echo
    echo "######## $1"
}

step "Reset to the lecture 3 state (migrations up to 022)"
sh scripts/db-reset.sh 022 > /dev/null 2>&1 || fail "db-reset.sh 022 failed"
echo "reset done"

step "§1 Baseline: tickets, and tickets whose product code does not resolve"
sql < "$dir/baseline.sql" || fail "baseline"

step "§1 Before starting: what depends on tickets.product_code"
sql < "$dir/product_code_dependents.sql" || fail "dependency check"

step "§2 Unsafe one-step change (rolled back)"
sql_with_errors 23502 23503 42703 < "$dir/unsafe_change.sql" || fail "unsafe change"

step "§4 Compatibility before expansion"
sh "$dir/compatibility_matrix.sh"

step "§3 Expand: 030_expand_product_identity.sql"
sql < "$migrations/030_expand_product_identity.sql" || fail "030"

step "§4 Compatibility after expansion, before backfill"
sh "$dir/compatibility_matrix.sh"

step "§4 New reader before backfill"
sql < "$dir/new_reader.sql" || fail "new reader"

step "§4 New writer with a product id that does not exist (rolled back)"
{ echo "begin;"; cat "$dir/new_writer.sql"; echo "rollback;"; } \
    | sql_must_fail 23502 -v product_id=00000000-0000-0000-0000-000000000000 || fail "unknown product id"

step "§5 Backfill: 031 twice"
sql < "$migrations/031_backfill_ticket_product.sql" || fail "031"
sql < "$migrations/031_backfill_ticket_product.sql" || fail "031 second run"

step "§6 Old writer adds a late ticket, verify, backfill again, verify"
sql -v ticket_id=LAB04-LATE-1 -v ticket_code=LAB04-CODE-LATE-1 < "$dir/old_writer.sql" || fail "late ticket"
sql < "$dir/verify.sql" || fail "verify"
sql < "$migrations/031_backfill_ticket_product.sql" || fail "031 after late ticket"
sql < "$dir/verify.sql" || fail "verify"

step "§4 Mismatched references written directly in SQL (rolled back)"
sql_with_errors 23503 < "$dir/mismatch_test.sql" || fail "mismatch test"

step "§4 Compatibility after backfill"
sh "$dir/compatibility_matrix.sh"

step "§7 Require product_id while one ticket still has none"
sql -v ticket_id=LAB04-LATE-2 -v ticket_code=LAB04-CODE-LATE-2 < "$dir/old_writer.sql" || fail "second late ticket"
sql_must_fail 23502 < "$migrations/032_require_ticket_product.sql" || fail "032 should have failed"
sql < "$migrations/031_backfill_ticket_product.sql" || fail "031 before 032"
sql < "$dir/verify.sql" || fail "verify"
sql < "$migrations/032_require_ticket_product.sql" || fail "032"

step "§7 Old writer after 032"
sql_must_fail 23502 -v ticket_id=LAB04-LATE-3 -v ticket_code=LAB04-CODE-LATE-3 < "$dir/old_writer.sql" \
    || fail "old writer should be rejected"

step "§4 Compatibility once product_id is required"
sh "$dir/compatibility_matrix.sh"

step "Rollout decision: old writer after undoing 032's NOT NULL (rolled back)"
{ echo "begin;"; echo "alter table tickets alter column product_id drop not null;"; \
  cat "$dir/old_writer.sql"; cat "$dir/old_reader.sql"; echo "rollback;"; } | sql || fail "going back"

step "§8 Before removing tickets.product_code: database dependencies"
sql < "$dir/product_code_dependents.sql" || fail "dependency check"

step "§8 Before removing tickets.product_code: SQL files that still use it"
echo "(besides init/, the lecture 4 migrations and the lecture 4 experiments)"
grep -rl "product_code" database/postgres --include=*.sql | grep -vE "/lecture04/|/init/|/migrations/03" | sort

step "§8 Rehearse removing tickets.product_code (rolled back)"
sql_with_errors 2BP01 < "$dir/remove_legacy.sql" || fail "remove legacy rehearsal"

step "§4 Compatibility after dropping the column (inside a rolled-back transaction)"
sh "$dir/compatibility_matrix.sh" --after-drop

step "§9 Original tickets, prices and currencies"
sql < "$dir/verify.sql" || fail "verify"
sql < "$dir/final_reader.sql" || fail "final reader"

step "Changing a product id (rolled back)"
sql_with_errors 23503 42501 < "$dir/product_id_immutability.sql" || fail "product id immutability"

echo
echo "lab finished: database is at migration 032"
