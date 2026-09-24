#!/bin/sh
# Two sessions insert captured payments at the same time. Session A (USER-1,
# TICKET-1, metro) inserts and keeps its transaction open. Once A is waiting,
# session B inserts with a 1 second lock timeout, as USER-2 for another ticket:
#   run 1: TICKET-3, a metro ticket, so the same operator and day as A
#   run 2: TICKET-2, a bus ticket, so another operator
# The two payments share no ticket, user or reference. Every transaction is rolled back.
#
#   sh scripts/db-reset.sh 022
#   sh database/postgres/experiments/lecture03/summary_row_contention.sh
set -u
cd "$(dirname "$0")/../../../.."

session() {
    docker compose exec -T postgres psql -U mobility -d mobility -q "$@"
}

wait_for_session_a() {
    tries=0
    until [ "$(session -At -c "select count(*) from pg_stat_activity where state = 'active' and query like 'select pg_sleep(%'")" = "1" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 50 ]; then
            echo "session A never reached pg_sleep; stopping" >&2
            exit 1
        fi
        sleep 0.2
    done
}

run() {
    label=$1
    b_ticket=$2
    echo "== $label"

    session <<'EOF' &
begin;
insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status, created_utc)
values ('PAY-LOCK-A', 'USER-1', 'TICKET-1', 'gateway-lock-a', 36.00, 'DKK', 'Captured', '2026-04-29 10:00:00+00');
select pg_sleep(5);
rollback;
EOF
    wait_for_session_a

    session -v b_ticket="$b_ticket" <<'EOF'
\timing on
begin;
set local lock_timeout = '1s';
insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status, created_utc)
values ('PAY-LOCK-B', 'USER-2', :'b_ticket', 'gateway-lock-b', 36.00, 'DKK', 'Captured', '2026-04-29 11:00:00+00');
rollback;
EOF
    wait
}

run "B pays for TICKET-3 (metro: same operator and day as A)" TICKET-3
run "B pays for TICKET-2 (bus: another operator)" TICKET-2
