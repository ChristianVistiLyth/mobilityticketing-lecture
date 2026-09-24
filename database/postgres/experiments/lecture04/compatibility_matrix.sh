#!/bin/sh
# Runs every reader and writer against the current database, each one inside
# begin ... rollback, and reports whether it works and what it returned.
# With --after-drop, tickets.product_code is dropped first in the same
# transaction to rehearse the final stage.
#
#   sh database/postgres/experiments/lecture04/compatibility_matrix.sh [--after-drop]
set -u
cd "$(dirname "$0")/../../../.."
dir=database/postgres/experiments/lecture04

prelude=""
if [ "${1:-}" = "--after-drop" ]; then
    prelude="alter table tickets drop column product_code;"
fi

total=$(docker compose exec -T postgres psql -U mobility -d mobility -At -c "select count(*) from tickets")
echo "tickets stored: $total"

for script in old_writer old_reader new_writer new_reader final_writer final_reader; do
    output=$({ echo "begin;"; echo "$prelude"; cat "$dir/$script.sql"; echo "rollback;"; } \
        | docker compose exec -T postgres psql -U mobility -d mobility -v ON_ERROR_STOP=1 2>&1)
    if [ $? -eq 0 ]; then
        result=$(printf '%s\n' "$output" | grep -E '^INSERT|^\([0-9]+ rows?\)' | tail -1)
        printf '%-13s works: %s\n' "$script" "$result"
    else
        error=$(printf '%s\n' "$output" | grep -m1 '^ERROR' | sed 's/^ERROR: *//')
        printf '%-13s FAILS: %s\n' "$script" "$error"
    fi
done
