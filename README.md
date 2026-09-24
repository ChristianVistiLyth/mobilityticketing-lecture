# MobilityTicketing database

PostgreSQL work for the MobilityTicketing case: a relational model for routes and timetables (lecture 1), rules the database enforces for ticket purchase and validation (lecture 2), a comparison of where reporting logic should run (lecture 3), and a product-identity migration that keeps old and new application versions working (lecture 4).

## Setup and reset

Requirements: Docker Desktop with Compose, and a POSIX shell for the scripts (Git Bash on Windows). Port 5432 must be free, so stop other course containers first.

```bash
sh scripts/db-reset.sh
```

[`scripts/db-reset.sh`](scripts/db-reset.sh) deletes the database volume, starts PostgreSQL, lets it run `database/postgres/init/`, and then applies `database/postgres/migrations/` in order. An optional argument stops after that migration, which gives the starting point for each lecture:

| Command | Database state |
| --- | --- |
| `sh scripts/db-reset.sh 000` | Lecture 1 model and seed, plus the starter ticketing tables without constraints |
| `sh scripts/db-reset.sh 011` | + lecture 2 constraints |
| `sh scripts/db-reset.sh 022` | + lecture 3 reporting objects (starting point of lecture 4) |
| `sh scripts/db-reset.sh` | + lecture 4 migrations (final state) |

Connect with `docker compose exec postgres psql -U mobility -d mobility`, or at `localhost:5432` with database, user and password `mobility`.

`docker compose stop` and `docker compose start` keep the data. `docker compose down` does not: the next `up` starts from an empty database with the init scripts only, so the migrations are gone. Use `sh scripts/db-reset.sh` to get back to a known state.

Scripts are run from the repository root. SQL files are passed on standard input, for example `docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/queries/base_revenue.sql`. Our experiment scripts roll back their own changes. Two starter files do not: `experiments/lecture02/constraints_should_fail.sql` and `experiments/lecture03/reporting_cases.sql`. Their evidence pages say how to run them. Each evidence page has a "Reproduce" section with the exact commands.

## Repository layout

| Path | Contents |
| --- | --- |
| `database/postgres/init/` | Run automatically on an empty database: lecture 1 schema and seed, plus the starter ticketing schema, seed and lecture 4 fixture, unchanged |
| `database/postgres/migrations/` | Our changes, applied in order: `011` constraints, `020`–`022` reporting, `030`–`032` product identity |
| `database/postgres/queries/` | Workload queries (lecture 1) and the reference revenue query (lecture 3) |
| `database/postgres/tests/` | Constraint tests that assert SQLSTATE codes and constraint names |
| `database/postgres/experiments/lectureNN/` | Scripts that produce the evidence for each lecture |
| `docs/evidence/lectureNN/` | Results and write-ups for each lecture |

# Compulsory Assignment 1 review guide

- Group members: *to be filled in*
- Submitted commit: *to be filled in*
- Setup and reset instructions: [Setup and reset](#setup-and-reset)

## Where to find the work

- **Lecture 1: model, workload map and queries:** [write-up with workload map and functional dependency](docs/evidence/lecture01/README.md) · [ER diagram](docs/evidence/lecture01/README.md#relational-model) · [schema](database/postgres/init/001_relational_baseline.sql) · [seed](database/postgres/init/002_seed.sql) and [trips](database/postgres/init/011_ticketing_seed.sql) · [queries](database/postgres/queries/003_queries.sql.example)
- **Lecture 2: constraints and tests:** [evidence](docs/evidence/lecture02/README.md) · [integrity map](docs/evidence/lecture02/integrity-map.md) · [migration](database/postgres/migrations/011_ticketing_integrity.sql) · [tests](database/postgres/tests/011_ticketing_integrity_test.sql)
- **Lecture 3: reporting experiment and comparison:** [evidence, matrix and recommendation](docs/evidence/lecture03/README.md) · [function](database/postgres/migrations/020_reporting_function.sql) · [trigger table](database/postgres/migrations/021_daily_revenue_trigger.sql) · [materialized view](database/postgres/migrations/022_daily_captured_revenue.sql) · [comparison script](database/postgres/experiments/lecture03/reporting_comparison.sql)
- **Lecture 4: migration stages and verification:** [evidence](docs/evidence/lecture04/README.md) · [expand](database/postgres/migrations/030_expand_product_identity.sql) · [backfill](database/postgres/migrations/031_backfill_ticket_product.sql) · [require](database/postgres/migrations/032_require_ticket_product.sql) · [whole run](database/postgres/experiments/lecture04/run_lab.sh)

## Two decisions worth discussing

### 1. Composite foreign keys where two columns must name the same row

**What we chose.** `validations (ticket_id, ticket_code) → tickets (id, ticket_code)` in lecture 2, and `tickets (product_id, product_code) → products (id, code)` while both product references exist in lecture 4.

**The alternative.** One foreign key per column, as in the supplied lecture 4 design, or dropping the duplicated column.

**Why it fits MobilityTicketing.** A validation must never combine one ticket's id with another ticket's code. During the migration, old and new application versions write at the same time, and the database is the only layer that sees every writer. With single-column keys each value exists on its own, so a mismatched pair is accepted.

**Evidence.** Test "ticket id combined with the code of another ticket" is rejected with `23503 validations_ticket_fk` ([run](docs/evidence/lecture02/README.md#test-run)). [`mismatch_test.sql`](database/postgres/experiments/lecture04/mismatch_test.sql) is rejected by `tickets_product_pair_fk` and accepted once that key is dropped ([result](docs/evidence/lecture04/README.md#4-both-versions-side-by-side)). The price is a unique key on `(id, ticket_code)` that adds nothing to uniqueness but is required as a foreign-key target, the opposite of lecture 1, where the extra unique constraint was dead weight.

### 2. Revenue is computed from payments, not maintained inside the purchase

**What we chose.** `payments` is the only authority. Reports read `captured_revenue_for_day`. The materialized view is an optional cache on a refresh schedule: a plain refresh once, then `refresh … concurrently`.

**The alternative.** The trigger-maintained `daily_revenue_by_operator` table.

**Why it fits MobilityTicketing.** Reporting may lag, but purchases at rush hour are correctness-critical. The trigger only follows inserts. It also makes every captured payment write, and lock, the one summary row for its operator and day.

**Evidence.** After the `Failed → Captured` correction, the live query shows 122.00 DKK and the trigger table 36.00 ([comparison](docs/evidence/lecture03/README.md#one-example-where-two-approaches-disagree), [short demo](docs/evidence/lecture03/README.md#for-the-review-meeting)). In the [contention test](docs/evidence/lecture03/README.md#side-effect-trace-of-one-payment-insert), a metro payment for another ticket and another user waited one second and then failed inside the reporting trigger, while a bus payment went through in a few milliseconds. Duplicate delivery is stopped at write time by the lecture 2 index: without it, even the live query counts the duplicate.

## One limitation or open question

**Nothing stops two purchases from taking the last seat.** `trips_reserved_seats_within_capacity` checks one row. Two transactions that both read `reserved_seats = capacity - 1` both write a row that passes the check ([integrity map #17](docs/evidence/lecture02/integrity-map.md#integrity-map), [boundary](docs/evidence/lecture02/README.md#rules-a-constraint-cannot-solve)). We have not demonstrated the race: the lab leaves concurrency for a later lecture. The counter is not tied to the tickets either: in the seed, `TRIP-M2-20260429-0800` counts two reserved seats for one ticket ([`seat_counter_drift.sql`](database/postgres/experiments/lecture02/seat_counter_drift.sql), [Issue 1](docs/evidence/lecture02/integrity-map.md#issue-1)).

**What we would check next.** Run two concurrent sessions buying the last seat, first with the purchase written as "read, then update", then as `update trips set reserved_seats = reserved_seats + 1 where id = $1 and reserved_seats < capacity`. Then decide whether the counter should be stored at all, or derived from tickets.
