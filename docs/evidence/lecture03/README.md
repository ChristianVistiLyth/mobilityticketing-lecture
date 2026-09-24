# Lecture 3: Where should reporting logic execute?

Operators need daily captured revenue. We compared four ways to produce it. The `payments` table is the authority, and everything else is derived from it.

| Approach | Object | File |
| --- | --- | --- |
| 1. Direct query | – | [`queries/base_revenue.sql`](../../../database/postgres/queries/base_revenue.sql) |
| 2. SQL function | `captured_revenue_for_day(operator_id, date)` | [`migrations/020_reporting_function.sql`](../../../database/postgres/migrations/020_reporting_function.sql) |
| 3. Materialized view | `daily_captured_revenue` | [`migrations/022_daily_captured_revenue.sql`](../../../database/postgres/migrations/022_daily_captured_revenue.sql) |
| 4. Trigger-maintained table | `daily_revenue_by_operator` + `payments_daily_revenue_after_insert` | [`migrations/021_daily_revenue_trigger.sql`](../../../database/postgres/migrations/021_daily_revenue_trigger.sql) |

The objects are kept exactly as supplied. In particular, the trigger only reacts to inserts.

Experiments in [`experiments/lecture03/`](../../../database/postgres/experiments/lecture03/):

| Script | Shows |
| --- | --- |
| [`reporting_cases.sql`](../../../database/postgres/experiments/lecture03/reporting_cases.sql) | the six supplied cases (starter file) |
| [`reporting_comparison.sql`](../../../database/postgres/experiments/lecture03/reporting_comparison.sql) | the same cases with all four approaches printed after each one, a rebuild, and case 6 without the lecture 2 index |
| [`payment_side_effects.sql`](../../../database/postgres/experiments/lecture03/payment_side_effects.sql) | everything one payment insert causes |
| [`summary_row_contention.sh`](../../../database/postgres/experiments/lecture03/summary_row_contention.sh) | two concurrent payments competing for one summary row |
| [`timezone_day_boundary.sql`](../../../database/postgres/experiments/lecture03/timezone_day_boundary.sql) | the reporting day depends on the session time zone |
| [`stale_report_demo.sql`](../../../database/postgres/experiments/lecture03/stale_report_demo.sql) | short version for the review meeting: one stale and one incorrect result, and how each is corrected |

## Reproduce

```bash
sh scripts/db-reset.sh 022
docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/queries/base_revenue.sql
docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture03/reporting_comparison.sql
docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture03/payment_side_effects.sql
sh database/postgres/experiments/lecture03/summary_row_contention.sh
docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture03/timezone_day_boundary.sql
docker compose exec -T postgres psql -U mobility -d mobility < database/postgres/experiments/lecture03/stale_report_demo.sql
```

Every script above rolls back, so they can run in any order on the same database. Do not pass `ON_ERROR_STOP` to the comparison script, because two of its steps are expected to fail.

The starter's `reporting_cases.sql` does **not** roll back. It commits its six changes, so run it only on a freshly reset database, and reset again afterwards.

In this repository the reporting objects sit on top of the lecture 2 constraints. That matters for case 6.

## Reference query on the base tables

```text
 operator_id | revenue_date | captured_amount | captured_payments
-------------+--------------+-----------------+-------------------
 OP-BUS      | 2026-04-29   |           36.00 |                 1
 OP-METRO    | 2026-04-29   |           36.00 |                 1
```

Checked by hand: the seed has two captured payments. `PAYMENT-1` reaches `OP-METRO` through `TICKET-1 → TRIP-M2-20260429-0800 → LINE-M2`, and `PAYMENT-2` reaches `OP-BUS` through `TICKET-2 → TRIP-5C-20260429-0900 → LINE-5C`.

## All four approaches, case by case

Values are `captured amount (captured payments)` for 29 April. Output from `reporting_comparison.sql`:

```text
== 0a. Materialized view before its first refresh
ERROR:  materialized view "daily_captured_revenue" has not been populated
HINT:  Use the REFRESH MATERIALIZED VIEW command.
== 0b. Baseline, after one refresh of the materialized view
 operator_id | revenue_date | direct_query | sql_function | materialized_view | trigger_table
-------------+--------------+--------------+--------------+-------------------+---------------
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)

== 1. Captured payment insert: PAY-CASE-CAPTURED, 36 DKK on TICKET-1 (metro)
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 72.00 (2)    | 72.00 (2)    | 36.00 (1)         | 36.00 (1)

== 2. Failed payment insert: PAY-CASE-FAILED, 50 DKK
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 72.00 (2)    | 72.00 (2)    | 36.00 (1)         | 36.00 (1)

== 3. Correction Failed -> Captured: PAY-CASE-FAILED
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 122.00 (3)   | 122.00 (3)   | 36.00 (1)         | 36.00 (1)

== 4. Correction Captured -> Refunded: PAY-CASE-CAPTURED
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 86.00 (2)    | 86.00 (2)    | 36.00 (1)         | 36.00 (1)

== 5. Delete test data: PAY-CASE-FAILED
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)

== 6. Duplicate delivery of gateway-capture-0001
ERROR:  duplicate key value violates unique constraint "payments_captured_reference_unique"
DETAIL:  Key (external_payment_reference)=(gateway-capture-0001) already exists.
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)

== 7. Rebuild both stored copies from payments
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)
 OP-METRO    | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)

== 8. Case 6 again without the lecture 2 index payments_captured_reference_unique
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)
 OP-METRO    | 2026-04-29   | 72.00 (2)    | 72.00 (2)    | 36.00 (1)         | 72.00 (2)
```

What happened:

| Case | Direct query and function | Materialized view | Trigger table |
| --- | --- | --- | --- |
| 0 | Correct | Unreadable until the first refresh, then correct | Empty: payments from before the trigger existed are never counted (no backfill) |
| 1 Captured insert | Correct (72.00) | Stale (36.00) | +36, but still missing the seed payments |
| 2 Failed insert | Unchanged, correct | Unchanged | Ignored, correct |
| 3 Failed → Captured | Correct (122.00) | Stale | **Missed**: there is no update trigger |
| 4 Captured → Refunded | Correct (86.00) | Stale | **Still counts the refunded 36** |
| 5 Delete | Correct (36.00) | Happens to match | Happens to match for metro. But its 36 is the refunded `PAY-CASE-CAPTURED`, not `PAYMENT-1`. Bus is still 0 |
| 6 Duplicate reference | Rejected at write time by the lecture 2 index. No report changes | – | – |
| 7 Rebuild | – | `refresh` makes it correct | `truncate` + insert from the base query makes it correct |
| 8 Duplicate without the index | Counts it twice (72.00) | Stale | Counts it twice (72.00) |

### One example where two approaches disagree

After case 3, the direct query says metro captured **122.00 DKK from 3 payments**, while the trigger table and the materialized view both say **36.00 DKK from 1**. The two stored copies are wrong for different reasons, and only one of them heals itself:

- The **materialized view** is stale. It changes only when someone runs `refresh materialized view daily_captured_revenue`, and step 7 shows that one refresh makes it correct.
- The **trigger table** is incorrect. It changes only when a new captured payment is inserted, so no later event ever corrects case 3. Its only fix is a full rebuild from `payments` (step 7).

Case 5 is the warning sign: all four columns show 36.00 for metro, but the trigger table is counting the wrong payment. Equal numbers are not proof that a copy is correct.

Case 8 shows that duplicate delivery is a write-time problem. Without the lecture 2 index, even the always-fresh direct query counts the duplicate. No reporting design can fix data that should not have been stored.

## Side-effect trace of one payment insert

From `payment_side_effects.sql`, one captured 36 DKK payment for `TICKET-1`:

```text
            trigger_name             | internal |   for_constraint
-------------------------------------+----------+--------------------
 payments_daily_revenue_after_insert | f        | -
 RI_ConstraintTrigger_c_16512        | t        | payments_ticket_fk
 RI_ConstraintTrigger_c_16513        | t        | payments_ticket_fk
 RI_ConstraintTrigger_c_16517        | t        | payments_user_fk
 RI_ConstraintTrigger_c_16518        | t        | payments_user_fk

 Insert on payments (actual rows=0 loops=1)
   ->  Result (actual rows=1 loops=1)
 Trigger for constraint payments_ticket_fk: calls=1
 Trigger for constraint payments_user_fk: calls=1
 Trigger payments_daily_revenue_after_insert: calls=1

         relation          |       mode
---------------------------+------------------
 daily_revenue_by_operator | RowExclusiveLock
 operators                 | RowShareLock
 payments                  | RowExclusiveLock
 routes                    | AccessShareLock
 tickets                   | AccessShareLock
 tickets                   | RowShareLock
 trips                     | AccessShareLock
 users                     | RowShareLock

        table_name         |       row_key       | xmin | xmax
---------------------------+---------------------+------+------
 payments                  | PAY-TRACE-1         | 796  | 0
 daily_revenue_by_operator | OP-METRO 2026-04-29 | 796  | 0
 tickets                   | TICKET-1            | 758  | 796
 users                     | USER-1              | 757  | 796
 operators                 | OP-METRO            | 745  | 796
```

Our transaction was `796`. It wrote the payment and the summary row (`xmin = 796`), and it holds row locks on the ticket, user and operator (`xmax = 796` on rows it did not change).

1. **Constraints and references checked.** On the row: `NOT NULL`, `payments_amount_non_negative`, `payments_currency_iso_format`, `payments_status_known` and `payments_captured_has_reference`. Unique indexes: `payments_pkey`, and `payments_captured_reference_unique` because the row is `Captured`. Foreign keys: `payments_ticket_fk` and `payments_user_fk` run as internal triggers and lock `TICKET-1` and `USER-1` with `FOR KEY SHARE`. Inside the reporting trigger, the summary table's own primary key and its foreign key to `operators` are checked too. That is why the `OP-METRO` row is locked.
2. **Trigger execution.** `payments_daily_revenue_after_insert` fires after the insert, once per row, and only does work for `Captured`. It joins `tickets`, `trips` and `routes` (the `AccessShareLock`s) to find the operator.
3. **Summary-table writes.** One upsert into `daily_revenue_by_operator`. The first payment of an operator-day inserts the row, and later payments update the same row.
4. **Rows and locks touched.** See the output above. The summary row stays locked until the payment transaction ends. `summary_row_contention.sh` shows the cost. Session A (`USER-1`, `TICKET-1`) inserts a captured metro payment and keeps its transaction open. Once A is waiting, session B pays as `USER-2` for another ticket, with a 1 second lock timeout:

   ```text
   == B pays for TICKET-3 (metro: same operator and day as A)
   Time: 1005.130 ms (00:01.005)
   ERROR:  canceling statement due to lock timeout
   CONTEXT:  while inserting index tuple (0,3) in relation "daily_revenue_by_operator"
   ...
   PL/pgSQL function add_inserted_payment_to_daily_revenue() line 16 at SQL statement
   == B pays for TICKET-2 (bus: another operator)
   Time: 9.331 ms
   ```

   The two metro payments share no ticket, user or gateway reference, only the operator and day. Payment B still waited for A's transaction and then failed, and the `CONTEXT` lines show the wait was inside the reporting trigger's upsert. Every captured payment for one operator on one day has to write the same summary row, which is the rush-hour case.
5. **Commit or rollback.** The payment and the summary row are in the same transaction. After `rollback`, both are gone (`trace_payments = 0, summary_rows = 0`). A failure in the trigger, such as the lock timeout above, fails the payment itself.
6. **When each report becomes current.** Direct query and function: at commit, and inside the transaction already. Trigger table: at commit, but only for inserts (before commit it showed 36.00 against the direct query's 72.00, because of the missing backfill). Materialized view: only at its next refresh.
7. **What the application can observe.** `INSERT 0 1` and nothing else. The summary write is invisible except as extra time on the insert and as errors that look like payment errors.

## Responsibility matrix

| | Direct query | SQL function | Materialized view | Trigger table |
| --- | --- | --- | --- | --- |
| Authority | `payments`, read live | `payments`, read live | Derived copy of `payments` | Derived copy that looks current but only follows inserts |
| Correctness | Always matches `payments` | Same as direct query | Correct as of the last refresh | Wrong after backfill, status corrections and deletes |
| Freshness rule | At read | At read | At the last `refresh` | Per insert, same transaction |
| Write cost | None | None | None on writes. A refresh recomputes everything | A 3-table join and an upsert inside every captured payment, plus a row lock per operator-day |
| Read cost | Joins 4 tables and aggregates. Grows with `payments` | Same, for one operator-day | Index lookup | Primary-key lookup |
| Hidden side effects | None | None (`stable`) | A plain refresh blocks readers. `concurrently` avoids that (the unique index exists) | Runs inside the purchase transaction: lock waits and failures hit payments |
| Rebuildability | Nothing to rebuild | Nothing to rebuild | `refresh materialized view` (a plain refresh the first time, `concurrently` after that) | Hand-written `truncate` + insert from the base query |
| Operational complexity | Low | Low | Medium: schedule refreshes, show refresh time | High: update/delete branches, backfill, contention |

## Recommendation

**`payments` stays the only authority. Operators read revenue through `captured_revenue_for_day` (or the base query for ranges). If those reads become too expensive, `daily_captured_revenue` is added as a cache refreshed on a schedule. The trigger-maintained table should be removed.**

This follows the workload description rather than preference:

- Reporting "can tolerate more latency" and "does not need to reflect every operational write immediately". Nothing requires revenue to be updated inside the payment transaction.
- Ticket purchase is correctness-critical and must hold up at rush hour. The trigger puts a reporting write and a shared hot row into every purchase, and the contention test shows a purchase failing because of it.
- Corrections and refunds are normal (cases 3 and 4). Approaches that recompute from `payments` handle them automatically. The trigger would need an update branch, a delete branch and a backfill before it is correct.
- Duplicate delivery is handled where it belongs: the lecture 2 index rejects it at write time (case 6), and without the index every approach reading `payments` is wrong (case 8).

For the stored copy we keep, the materialized view: its authority is `payments`, and its freshness is "as of the last refresh" (the report should show that time). Its rebuild path is `refresh materialized view daily_captured_revenue` once after the migration, because 022 creates it empty and PostgreSQL refuses `concurrently` on a view that was never populated. After that, the scheduled job runs `refresh materialized view concurrently daily_captured_revenue`, so reports keep working during the refresh. The function needs no rebuild path.

The trigger and summary table stay in `021_daily_revenue_trigger.sql` for now, so the experiment and the incorrect result can be reproduced for review. In a real rollout, a follow-up migration would drop them.

### Decision record

- **Context.** Daily captured revenue per operator. `payments` changes by insert, status correction, refund and occasional delete. Reports may lag. Purchases may not.
- **Decision.** Compute revenue from `payments` through the function. Allow the materialized view as a scheduled cache. Do not maintain revenue inside the payment transaction.
- **Alternatives.** Trigger-maintained table: rejected, see cases 0, 3 and 4 and the contention test. Materialized view only: acceptable for dashboards, but a stale result must never be presented as final.
- **Consequences.** Dashboards can lag by one refresh interval, and someone has to own the refresh schedule. Month-end figures should come from the function. The purchase path carries no reporting work.

## Issue register

### Issue 1: the summary table only follows inserts

- Evidence: comparison cases 0, 3 and 4 above.
- Problem: `payments_daily_revenue_after_insert` is an `after insert` trigger. Status corrections, refunds and deletes never reach `daily_revenue_by_operator`, and rows from before the trigger existed are never added.
- Consequence: operator revenue is wrong until someone rebuilds the table, and nothing shows that it is wrong. Case 5 even shows the right total for the wrong reason.
- Specific improvement: stop maintaining it (recommendation above). If it had to stay, it would need `after update` and `after delete` branches that subtract the old row and add the new one, a one-off backfill, and a periodic reconciliation against the base query.
- Open question: is there any report that must be exact at the moment of purchase? If not, the table has no reason to exist.

### Issue 2: the reporting day depends on the session time zone

- Evidence: [`timezone_day_boundary.sql`](../../../database/postgres/experiments/lecture03/timezone_day_boundary.sql). A payment at 22:30 UTC on 29 April was inserted by a Copenhagen session:

```text
              source               | revenue_date | captured_amount | captured_payments
-----------------------------------+--------------+-----------------+-------------------
 materialized view (UTC refresh)   | 2026-04-29   |           72.00 |                 2
 trigger table (Copenhagen insert) | 2026-04-30   |           36.00 |                 1

 session_time_zone | captured_amount | captured_payments
-------------------+-----------------+-------------------
 UTC               |               0 |                 0
 Europe/Copenhagen |           36.00 |                 1
```

- Problem: every approach uses `created_utc::date`, and that cast depends on the `TimeZone` setting of whichever session runs it: the inserting session for the trigger, the refreshing session for the view, the reading session for the function.
- Consequence: the same function call returns different revenue depending on how a client connected, and two copies can put one payment on different days.
- Specific improvement: define the reporting day in one place, for example an immutable SQL function `reporting_day(timestamptz)` returning `(ts at time zone 'Europe/Copenhagen')::date`, and use it in the function, the view and any rebuild query. Today the same cast is written separately in the function, the view, the trigger and every query script, which is how copies drift apart. The lecture 3 objects are kept as supplied, so this is a proposal, not a change.
- Open question: do operators report by local business day or by UTC day, and is a night bus after midnight part of the previous service day?

## For the review meeting

[`stale_report_demo.sql`](../../../database/postgres/experiments/lecture03/stale_report_demo.sql) is the short version, run after `sh scripts/db-reset.sh 022`. Both stored copies start out correct, so the only change is one `Failed → Captured` correction:

```text
== A failed 50 DKK metro payment is corrected to Captured
INSERT 0 1
UPDATE 1
== Base-table query (queries/base_revenue.sql): the authority
 operator_id | revenue_date | captured_amount | captured_payments
-------------+--------------+-----------------+-------------------
 OP-BUS      | 2026-04-29   |           36.00 |                 1
 OP-METRO    | 2026-04-29   |           86.00 |                 2
== Materialized view: stale, changes only when refreshed
 OP-BUS      | 2026-04-29   |           36.00 |                 1
 OP-METRO    | 2026-04-29   |           36.00 |                 1
== Trigger table: wrong, changes only when a captured payment is inserted
 OP-BUS      | 2026-04-29   |           36.00 |                 1
 OP-METRO    | 2026-04-29   |           36.00 |                 1
== Refresh the view. The trigger table is still wrong
      source       | operator_id | revenue_date | captured_amount | captured_payments
-------------------+-------------+--------------+-----------------+-------------------
 materialized view | OP-BUS      | 2026-04-29   |           36.00 |                 1
 trigger table     | OP-BUS      | 2026-04-29   |           36.00 |                 1
 materialized view | OP-METRO    | 2026-04-29   |           86.00 |                 2
 trigger table     | OP-METRO    | 2026-04-29   |           36.00 |                 1
== Rebuild the trigger table from payments
 OP-BUS      | 2026-04-29   |           36.00 |                 1
 OP-METRO    | 2026-04-29   |           86.00 |                 2
```

- **When the result changes.** The materialized view changes only when someone refreshes it. The trigger table changes only when a captured payment is inserted, and a status update is not an insert, so no later event will ever correct it.
- **How each copy is corrected.** The view with `refresh materialized view`. The trigger table only by rebuilding it from `payments`.
