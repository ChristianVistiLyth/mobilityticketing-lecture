# MobilityTicketing database

PostgreSQL work for the MobilityTicketing lectures. Everything for one lecture is in its folder, `lecture01` to `lecture04`.

## Setup and reset

You need Docker Desktop and a POSIX shell (Git Bash on Windows). Port 5432 must be free.

```bash
sh scripts/db-reset.sh        # empty database, then all migrations
sh scripts/db-reset.sh 011    # stop after lecture 2
sh scripts/db-reset.sh 022    # stop after lecture 3
sh scripts/db-reset.sh 000    # no migrations
```

The script recreates the database. Docker runs the `init/` files listed in `compose.yaml`, and the script then applies every `lectureNN/migrations/` file in number order. `docker compose stop` and `start` keep the data. `docker compose down` does not.

Connect with `docker compose exec postgres psql -U mobility -d mobility`. Each lecture README lists the commands that reproduce its results.

# Compulsory Assignment 1 review guide

- Group members: Christian Visti Lyth
- Setup and reset instructions: [Setup and reset](#setup-and-reset)

## Where to find the work

- **Lecture 1: model, workload map and queries:** [README](lecture01/README.md) · [ER diagram](lecture01/README.md#er-diagram) · [schema](lecture01/init/001_relational_baseline.sql) · [queries](lecture01/queries/003_queries.sql.example)
- **Lecture 2: constraints and tests:** [README](lecture02/README.md) · [integrity map](lecture02/integrity-map.md) · [migration](lecture02/migrations/011_ticketing_integrity.sql) · [tests](lecture02/tests/011_ticketing_integrity_test.sql)
- **Lecture 3: reporting experiment and comparison:** [README](lecture03/README.md) · [migrations](lecture03/migrations/) · [comparison](lecture03/experiments/reporting_comparison.sql)
- **Lecture 4: migration stages and verification:** [README](lecture04/README.md) · [migrations](lecture04/migrations/) · [full run](lecture04/experiments/run_lab.sh)

## Two decisions worth discussing

### 1. Composite foreign keys for pairs of columns

**What we chose.** `validations (ticket_id, ticket_code) → tickets (id, ticket_code)` in lecture 2, and `tickets (product_id, product_code) → products (id, code)` during the lecture 4 migration.

**The alternative.** One foreign key per column.

**Why it fits.** A validation must never mix one ticket's id with another ticket's code, and during a migration old and new code write at the same time. With single-column keys each value exists on its own, so a mismatched pair is accepted.

**Evidence.** The [tests](lecture02/README.md#tests) reject a mismatched pair with `23503 validations_ticket_fk`, and the [lecture 4 mismatch test](lecture04/README.md#4-both-versions-side-by-side) is rejected by `tickets_product_pair_fk`.

### 2. Revenue is computed from payments

**What we chose.** `payments` is the only authority, and reports use the function `captured_revenue_for_day`. The materialized view is an optional cache on a refresh schedule.

**The alternative.** The trigger-maintained table `daily_revenue_by_operator`.

**Why it fits.** Reports may lag, but purchases at rush hour must be correct. The trigger only follows inserts, and it writes and locks a summary row inside every payment.

**Evidence.** After a `Failed → Captured` correction, the live query shows 122.00 DKK while the trigger table shows 36.00 ([comparison](lecture03/README.md#where-two-approaches-disagree)). The [side-effect trace](lecture03/README.md#side-effect-trace-of-one-payment-insert) shows the extra writes and locks.

## One limitation or open question

**Nothing stops two purchases from taking the last seat.** `trips_reserved_seats_within_capacity` checks one row at a time, so two transactions that both see one free seat can both write a valid row ([boundary](lecture02/README.md#rules-a-constraint-cannot-solve)). The seat count is not tied to the tickets either ([Issue 1](lecture02/integrity-map.md#issue-1)).

**What we would check next.** Run two sessions that buy the last seat at the same time, then change the purchase to `update trips set reserved_seats = reserved_seats + 1 where id = $1 and reserved_seats < capacity`.
