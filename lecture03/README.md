# Lecture 3: Where should reporting logic execute?

Daily captured revenue per operator, built four ways. `payments` is the authority.

| Approach | File |
| --- | --- |
| 1. Direct query | [queries/base_revenue.sql](queries/base_revenue.sql) |
| 2. SQL function `captured_revenue_for_day` | [migrations/020_reporting_function.sql](migrations/020_reporting_function.sql) |
| 3. Trigger-maintained table `daily_revenue_by_operator` | [migrations/021_daily_revenue_trigger.sql](migrations/021_daily_revenue_trigger.sql) |
| 4. Materialized view `daily_captured_revenue` | [migrations/022_daily_captured_revenue.sql](migrations/022_daily_captured_revenue.sql) |

The objects are kept as supplied. The trigger only reacts to inserts. Experiments: the teacher's [reporting_cases.sql](experiments/reporting_cases.sql), our [reporting_comparison.sql](experiments/reporting_comparison.sql) (the same six cases, printing all four approaches after each one), and [payment_side_effects.sql](experiments/payment_side_effects.sql).

## Reproduce

```bash
sh scripts/db-reset.sh 022
docker compose exec -T postgres psql -U mobility -d mobility < lecture03/queries/base_revenue.sql
docker compose exec -T postgres psql -U mobility -d mobility < lecture03/experiments/reporting_comparison.sql
docker compose exec -T postgres psql -U mobility -d mobility < lecture03/experiments/payment_side_effects.sql
```

Both of our scripts roll back. The teacher's `reporting_cases.sql` commits its changes, so run it only on a freshly reset database.

## Base query

The base query returns `OP-BUS` 36.00 (1 payment) and `OP-METRO` 36.00 (1 payment) for 29 April. That matches the seed's two captured payments. `PAYMENT-1` goes through TICKET-1 → LINE-M2 → OP-METRO, and `PAYMENT-2` through TICKET-2 → LINE-5C → OP-BUS.

## The six cases

Metro revenue on 29 April after each case, as `amount (payments)`:

| After | Direct query and function | Materialized view | Trigger table |
| --- | --- | --- | --- |
| Start, view refreshed once | 36.00 (1) | 36.00 (1) | 0.00 (0): no backfill |
| 1. Captured insert | 72.00 (2) | 36.00 (1) stale | 36.00 (1) |
| 2. Failed insert | 72.00 (2) | 36.00 (1) | 36.00 (1) |
| 3. Failed → Captured | 122.00 (3) | 36.00 (1) | 36.00 (1): **missed** |
| 4. Captured → Refunded | 86.00 (2) | 36.00 (1) | 36.00 (1): **still counts the refund** |
| 5. Delete | 36.00 (1) | 36.00 (1) | 36.00 (1): right total, wrong payment |
| 6. Duplicate reference | Rejected by the lecture 2 index, nothing changes | | |
| Rebuild: `refresh` and recompute | 36.00 (1) | 36.00 (1) | 36.00 (1) |
| Duplicate again without the index | 72.00 (2) | 36.00 (1) | 72.00 (2) |

For bus, the trigger table shows 0.00 until the rebuild, and every other approach shows 36.00 throughout.

<details>
<summary>Output of reporting_comparison.sql</summary>

```text
== 0a. Materialized view before its first refresh
ERROR:  materialized view "daily_captured_revenue" has not been populated
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
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 0.00 (0)
 OP-METRO    | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)
== 7. Rebuild both stored copies from payments
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)
 OP-METRO    | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)
== 8. Case 6 again without the lecture 2 index payments_captured_reference_unique
 OP-BUS      | 2026-04-29   | 36.00 (1)    | 36.00 (1)    | 36.00 (1)         | 36.00 (1)
 OP-METRO    | 2026-04-29   | 72.00 (2)    | 72.00 (2)    | 36.00 (1)         | 72.00 (2)
```

</details>

## Where two approaches disagree

After case 3, the direct query shows **122.00 from 3 payments**, while the view and the trigger table both show **36.00 from 1**.

- The **view is stale**. It only changes on `refresh materialized view daily_captured_revenue`, and one refresh corrects it.
- The **trigger table is wrong**. It only changes when a captured payment is inserted, so no later event corrects it. The only fix is to rebuild it from `payments` (`truncate`, then insert from the base query).

Case 8 shows that duplicates are a write problem. Without the lecture 2 index, even the always-current query counts the duplicate twice.

## Side-effect trace of one payment insert

1. **Checks.** `NOT NULL`, the check constraints and the unique indexes run on the row. The foreign keys to the ticket and the user run as internal triggers and lock both rows (`FOR KEY SHARE`).
2. **Trigger.** `payments_daily_revenue_after_insert` fires after the insert, only for `Captured`, and joins tickets, trips and routes to find the operator.
3. **Summary write.** One upsert into `daily_revenue_by_operator`. Its own foreign key also locks the operator row.
4. **Rows and locks.** The payment row and the summary row are written. The ticket, user and operator rows are locked until the transaction ends. Every captured payment for the same operator and day needs that same summary row, so they wait for each other.
5. **Commit or rollback.** Everything is one transaction. A rollback removes the payment and the summary change together, and an error in the trigger fails the payment.
6. **When each report is current.** The direct query and the function are current at commit. The trigger table is current at commit too, but only for inserts. The view is current only after the next refresh.
7. **What the application sees.** Only `INSERT 0 1`. The summary write shows up only as extra time, or as an error on the payment.

<details>
<summary>Output of payment_side_effects.sql (our transaction was 796)</summary>

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

</details>

## Responsibility matrix

| | Direct query | Function | Materialized view | Trigger table |
| --- | --- | --- | --- | --- |
| Authority | `payments`, read live | `payments`, read live | Copy of `payments` | Copy that only follows inserts |
| Correctness | Always right | Always right | Right as of last refresh | Wrong after corrections, deletes and missing backfill |
| Freshness | At read | At read | At last refresh | Per insert |
| Write cost | None | None | None. A refresh recomputes everything | A join and an upsert inside every payment |
| Read cost | Joins four tables | Same, for one operator and day | Index lookup | Key lookup |
| Hidden side effects | None | None | A plain refresh blocks readers | Runs and locks inside the purchase |
| Rebuild path | Nothing to rebuild | Nothing to rebuild | A plain `refresh` once, then `refresh … concurrently` | Hand-written truncate and recompute |
| Operational complexity | Low | Low | Refresh schedule | Update and delete branches, backfill |

## Recommendation

`payments` stays the only authority. Reports use `captured_revenue_for_day`, and the materialized view can be added as a scheduled cache if reads get slow. The trigger table should be removed.

- Reporting can lag, and purchases at rush hour must be correct. Nothing requires revenue to be updated inside the payment.
- Corrections and refunds are normal (cases 3 and 4). Recomputing from `payments` handles them, and the trigger does not.
- Duplicates are stopped at write time by the lecture 2 index.

### Decision record

- **Context.** Operators need daily revenue. Payments are corrected and refunded, reports may lag, and purchases may not.
- **Decision.** Compute revenue from `payments` through the function, with the view as an optional cache.
- **Alternatives.** The trigger table, rejected because of cases 0, 3 and 4 and because it adds work and locks to every purchase. The view alone, which is fine for dashboards but must never be presented as final.
- **Consequences.** Dashboards lag by at most one refresh, someone owns the refresh schedule, and the purchase path does no reporting work.

## Issue register

- **Evidence:** cases 0, 3 and 4 above.
- **Problem:** the trigger is `after insert` only. Status changes, deletes and payments from before the trigger never reach the table.
- **Consequence:** operator revenue is wrong until someone rebuilds the table, and nothing shows that it is wrong.
- **Improvement:** drop the table, or add update and delete branches plus a one-off backfill.
- **Open question:** does any report have to be exact at the moment of purchase?
