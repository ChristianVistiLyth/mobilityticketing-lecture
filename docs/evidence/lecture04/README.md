# Lecture 4: Change product identity without breaking tickets

Tickets referred to products by `product_code`. They now refer to a stable `product_id`, and at no point did any ticket lose its product, its agreed price or its currency. Old and new application versions both kept working through the overlap.

| Stage | File |
| --- | --- |
| Expand: `products.id`, nullable `tickets.product_id`, `not valid` foreign keys | [`migrations/030_expand_product_identity.sql`](../../../database/postgres/migrations/030_expand_product_identity.sql) |
| Backfill (repeatable) | [`migrations/031_backfill_ticket_product.sql`](../../../database/postgres/migrations/031_backfill_ticket_product.sql) |
| Require: validate and `set not null` | [`migrations/032_require_ticket_product.sql`](../../../database/postgres/migrations/032_require_ticket_product.sql) |
| Remove `tickets.product_code` (rehearsal, rolled back) | [`experiments/lecture04/remove_legacy.sql`](../../../database/postgres/experiments/lecture04/remove_legacy.sql) |

Readers and writers in [`experiments/lecture04/`](../../../database/postgres/experiments/lecture04/):

- `old_writer` / `old_reader` use the code only.
- `new_writer` / `new_reader` use both references.
- `final_writer` / `final_reader` use the id only.

Checks: `baseline.sql`, `product_code_dependents.sql`, `verify.sql`, `mismatch_test.sql`, `unsafe_change.sql` and `product_id_immutability.sql`. `compatibility_matrix.sh` runs all six readers and writers against the current database, each inside `begin … rollback`.

## Reproduce

```bash
sh database/postgres/experiments/lecture04/run_lab.sh
```

[`run_lab.sh`](../../../database/postgres/experiments/lecture04/run_lab.sh) resets the database to the lecture 3 state (`db-reset.sh 022`) and runs every step on this page in order. Its step labels use the section numbers below.

- Each expected failure must fail with the SQLSTATE given in the script. Anything unexpected stops the run with exit code 1.
- The run ends at migration 032.
- All outputs here come from one run. Product ids are random, so they differ between runs.
- Errors show their SQLSTATE because the script uses `VERBOSITY=verbose`. The extra `SCHEMA NAME` / `TABLE NAME` lines are left out here.

The starting point is this repository's own migrations 011–022, not the lecture 4 starter's baseline. The lecture 2 constraints matter here: `tickets.product_code` is `NOT NULL` with a foreign key that uses `on delete restrict`.

## 1. Baseline

```text
    id    | product_code | price | currency
----------+--------------+-------+----------
 TICKET-1 | SINGLE       | 36.00 | DKK
 TICKET-2 | SINGLE       | 36.00 | DKK
 TICKET-3 | DAY          | 65.00 | DKK

 id | product_code          <- tickets whose code does not resolve to a product
----+--------------
(0 rows)
```

Three tickets and two products. `TICKET-3` was bought for 65 DKK, while the catalogue now lists `DAY` at 80 DKK. The migration must keep the 65. These values are hard-coded in the second check of [`verify.sql`](../../../database/postgres/experiments/lecture04/verify.sql).

**Before starting, what depends on `tickets.product_code`** ([`product_code_dependents.sql`](../../../database/postgres/experiments/lecture04/product_code_dependents.sql)):

```text
== Views and materialized views that use tickets.product_code (tracked by PostgreSQL)
(0 rows)
== Constraints on the column (dropped together with it)
 tickets_product_fk | f
== Functions whose body mentions product_code (function bodies are not tracked)
(0 rows)
```

The lecture 3 reporting objects do not use the column. The materialized view only reads `tickets.id` and `tickets.trip_id`, and PostgreSQL tracks view dependencies per column. The function bodies were searched as text, because PostgreSQL does not track them.

## 2. The unsafe one-step change

The obvious version: give products an id, drop `tickets.product_code`, and add a required `tickets.product_id`.

**Prediction, before running it.** Dropping `product_code` succeeds and silently takes `tickets_product_fk` with it. Adding a `NOT NULL` column fails, because existing tickets have no value for it. A random default gets past `NOT NULL`, but then the foreign key fails, because random ids match no product. Without a foreign key it would succeed and leave meaningless links. The old reader and writer fail as soon as `product_code` is gone.

**Result** ([`unsafe_change.sql`](../../../database/postgres/experiments/lecture04/unsafe_change.sql), in one rolled-back transaction):

```text
== 1. Give products an id, then replace the ticket reference in one go
ALTER TABLE
ALTER TABLE
ERROR:  23502: column "product_id" of relation "tickets" contains null values
== 2. Get past NOT NULL with a default
ERROR:  23503: insert or update on table "tickets" violates foreign key constraint "tickets_product_id_fkey"
DETAIL:  Key (product_id)=(1b221c0f-f6b5-4d45-9df0-1385d2a470be) is not present in table "products".
== 3. The old application after the drop
ERROR:  42703: column "product_code" does not exist
ERROR:  42703: column "product_code" of relation "tickets" does not exist
== 4. What is left to rebuild the ticket-product links from
    id    | user_id |        trip_id        |  ticket_code  |  status   | ... | price | currency
----------+---------+-----------------------+---------------+-----------+-----+-------+----------
 TICKET-1 | USER-1  | TRIP-M2-20260429-0800 | CODE-M2-0001  | Active    | ... | 36.00 | DKK
 TICKET-2 | USER-2  | TRIP-5C-20260429-0900 | CODE-5C-0001  | Validated | ... | 36.00 | DKK
 TICKET-3 | USER-1  | TRIP-M2-20260429-1200 | CODE-DAY-0001 | Active    | ... | 65.00 | DKK
```

**Why it is unsafe.**

- **How would existing tickets get their `product_id`?** Only from `product_code`, and that is exactly what the change drops first. Step 4 shows what is left: nothing links a ticket to a product. Price does not identify a product either (`TICKET-3` paid 65, not the catalogue's 80). Here the transaction saved us. Run as separate statements, the drop would have been committed on its own before the failure, and only a backup could restore the links.
- **What happens to code that still expects `product_code`?** It breaks at once. Every running application instance would have to switch at the moment of the migration, and that cannot be done. Changing a populated database is about ordering, which does not come up when creating a new one.

## 3. Expand

`030_expand_product_identity.sql` adds `products.id` (backfilled with `gen_random_uuid()`, then `default`, `not null`, `unique`), a nullable `tickets.product_id`, and two foreign keys marked `not valid`, both with `on delete restrict`:

- `tickets_product_id_fk`: `product_id → products(id)`, as in the lab.
- `tickets_product_pair_fk`: `(product_id, product_code) → products(id, code)`. This is our addition, and it relies on `products_id_code_unique`. While both references exist, they must name the same product. When `product_id` is null the check is skipped, so old writers are not affected. It is the same technique as `validations_ticket_fk` in lecture 2.

`set local lock_timeout = '3s'` and the large-table version are covered [below](#large-tables).

## 4. Both versions side by side

Output of `compatibility_matrix.sh` at each stage. "Stored" is the number of tickets in the table at that moment, because the late-ticket steps add some.

| Script | Before expansion (3 stored) | After expansion (3 stored) | After backfill (4 stored) | `product_id` required (5 stored) | `product_code` dropped (rehearsal, 5 stored) |
| --- | --- | --- | --- | --- | --- |
| `old_writer` | works | works | works | **fails**: `product_id` is `NOT NULL` | fails: no `product_code` |
| `old_reader` | works, 3 rows | works, 3 rows | works, 4 rows | works, 5 rows | fails |
| `new_writer` | fails: no `products.id` | works | works | works | fails: writes `product_code` |
| `new_reader` | fails | works, 3 rows | works, 4 rows | works, 5 rows | fails |
| `final_writer` | fails | fails: `product_code` is `NOT NULL` | fails: same | fails: same | works |
| `final_reader` | fails | **runs but returns 0 of 3 tickets** | works, 4 rows | works, 5 rows | works, 5 rows |

**A query that runs but misses tickets:** `final_reader` joins only through `product_id`. After expansion but before backfill, it returns no error and no rows. `new_reader` falls back to the code and resolves all three tickets before backfill:

```text
    id    |         resolved_product_id          | resolved_product_code | price | currency
----------+--------------------------------------+-----------------------+-------+----------
 TICKET-1 | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE                | 36.00 | DKK
 TICKET-2 | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE                | 36.00 | DKK
 TICKET-3 | 9a9f0765-bda1-4bdb-8400-c86ca1a8aa48 | DAY                   | 65.00 | DKK
```

**`final_writer` is blocked by our own lecture 2 rule.** `tickets.product_code` is `NOT NULL`, so an id-only insert fails until the column is removed. We kept it that way on purpose. It works as a latch: no ticket can be written without a code while any old reader might still depend on the code.

**The new writer takes a product id and the agreed price.** The code and currency are looked up from the product row, so the caller has no way to supply a code for another product. An unknown id is rejected, because the lookup returns no code:

```text
ERROR:  23502: null value in column "product_code" of relation "tickets" violates not-null constraint
DETAIL:  Failing row contains (LAB04-NEW-1, ..., 70.00, null, 00000000-0000-0000-0000-000000000000).
```

**Writing a mismatched pair directly in SQL** ([`mismatch_test.sql`](../../../database/postgres/experiments/lecture04/mismatch_test.sql), run after the backfill so the check below shows only this row): code `SINGLE` with the id of `DAY`.

```text
== 1. With tickets_product_pair_fk in place
ERROR:  23503: insert or update on table "tickets" violates foreign key constraint "tickets_product_pair_fk"
DETAIL:  Key (product_id, product_code)=(9a9f0765-bda1-4bdb-8400-c86ca1a8aa48, SINGLE) is not present in table "products".
== 2. With only the two single-column foreign keys
ALTER TABLE
INSERT 0 1
== 3. The first check in verify.sql finds it
       id       | product_code |              product_id              | code_of_product_id
----------------+--------------+--------------------------------------+--------------------
 LAB04-MISMATCH | SINGLE       | 9a9f0765-bda1-4bdb-8400-c86ca1a8aa48 | DAY
```

The writer preventing a mismatch and the database preventing it are two different guarantees. With only the lab's single-column foreign key, each value exists on its own and the database accepts the pair. The composite key closes that for any writer, not just ours.

## 5. Backfill, twice

```text
UPDATE 3
UPDATE 0
```

The second run changes nothing, because it only touches `product_id is null`.

## 6. A late ticket from an old writer

`old_writer.sql` adds `LAB04-LATE-1` after the backfill. `verify.sql` finds it, the backfill picks it up, and the check is empty again. The ids already assigned are unchanged (the backfill never updates a non-null `product_id`):

```text
INSERT 0 1
== 1. Tickets with no product id, an unknown product id, or an id and code for different products
      id      | product_code | product_id | code_of_product_id
--------------+--------------+------------+--------------------
 LAB04-LATE-1 | SINGLE       |            |
UPDATE 1
== 1. Tickets with no product id, an unknown product id, or an id and code for different products
(0 rows)
== 2. Original tickets whose product, price or currency changed (values from baseline.sql)
(0 rows)
```

## 7. Require the new reference

We deliberately added `LAB04-LATE-2` through the old writer first, then ran 032:

```text
INSERT 0 1
BEGIN
SET
ALTER TABLE
ALTER TABLE
ERROR:  23502: column "product_id" of relation "tickets" contains null values
(rejected with SQLSTATE 23502, as expected)
```

The database refused to finish the migration while a ticket still lacked the new reference. After another backfill run and an empty `verify.sql`, 032 committed. From then on, the old writer is rejected:

```text
ERROR:  23502: null value in column "product_id" of relation "tickets" violates not-null constraint
DETAIL:  Failing row contains (LAB04-LATE-3, USER-1, ..., SINGLE, ..., 36.00, DKK, null).
```

## 8. Rehearse removing `tickets.product_code`

First, [`product_code_dependents.sql`](../../../database/postgres/experiments/lecture04/product_code_dependents.sql) again, now at migration 032:

```text
== Views and materialized views that use tickets.product_code (tracked by PostgreSQL)
(0 rows)
== Constraints on the column (dropped together with it)
 tickets_product_fk      | f
 tickets_product_pair_fk | f
== Functions whose body mentions product_code (function bodies are not tracked)
(0 rows)
```

The database check is not enough on its own. Searching the repository finds SQL outside lecture 4 that still writes `product_code`:

```text
database/postgres/experiments/lecture02/constraints_should_fail.sql
database/postgres/migrations/011_ticketing_integrity.sql
database/postgres/tests/011_ticketing_integrity_test.sql
```

The migration only defines the column. The lecture 2 tests and the starter's negative writes insert tickets by code, so they need a rewrite before the drop is committed. Until then they run at migration level 011–031, and the test file refuses to run at 032.

Then the rehearsal itself ([`remove_legacy.sql`](../../../database/postgres/experiments/lecture04/remove_legacy.sql), rolled back):

```text
== 1. What leaving out CASCADE protects against: a view that still needs the column
CREATE VIEW
ERROR:  2BP01: cannot drop column product_code of table tickets because other objects depend on it
DETAIL:  view legacy_ticket_codes depends on column product_code of table tickets
HINT:  Use DROP ... CASCADE to drop the dependent objects too.
DROP VIEW
== 2. Drop the column once nothing depends on it
ALTER TABLE
 column_name | is_nullable
-------------+-------------
 product_id  | NO
== 3. The unique key that only served tickets_product_pair_fk can go too
ALTER TABLE
```

Without `CASCADE`, the drop stops at any view that still needs the column. With `CASCADE`, that view would silently disappear. Dropping the column takes both of its foreign keys with it. `products_id_code_unique` is then unused and can be dropped too. `products.code` stays as the business-facing product code.

## 9. Prices and currencies

Final `verify.sql` and `final_reader.sql` at migration 032:

```text
== 1. Tickets with no product id, an unknown product id, or an id and code for different products
(0 rows)
== 2. Original tickets whose product, price or currency changed (values from baseline.sql)
(0 rows)

      id      |              product_id              | product_code | price | currency
--------------+--------------------------------------+--------------+-------+----------
 LAB04-LATE-1 | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 LAB04-LATE-2 | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 TICKET-1     | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 TICKET-2     | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 TICKET-3     | 9a9f0765-bda1-4bdb-8400-c86ca1a8aa48 | DAY          | 65.00 | DKK
```

The same tickets exist, each is linked to its original product through the new id, and `TICKET-3` still has its 65 DKK price. None of the migrations read or write `price` or `currency`.

## Rollout decision

- **Stop the old writers before 032.** Section 7 shows the database refusing to finish while one old-writer ticket still lacks an id. The final check is a last backfill run plus an empty `verify.sql`. We cannot tell from the repository which application versions are still running, so we also need deployment information before running 032.
- **Old readers may keep running through 032.** `product_code` stays `NOT NULL` and is filled by every writer that can still run, so the old reader returns every ticket (5 of 5 in the matrix).
- **Move all readers to `final_reader` before the drop, and switch writers to `final_writer` together with the drop.** Until then, the `NOT NULL` on `product_code` is what stops id-only rows from appearing.
- **Could we return to the old version?** Up to and including 032, yes, cheaply. Undoing 032's `NOT NULL` makes the old writer work again, and every ticket still has its code:

```text
######## Rollout decision: old writer after undoing 032's NOT NULL (rolled back)
BEGIN
ALTER TABLE
INSERT 0 1
      id      | product_code | price | currency
--------------+--------------+-------+----------
 LAB04-LATE-1 | SINGLE       | 36.00 | DKK
 ...
(6 rows)
```

  After the column is dropped, there is no quick way back. Every old reader and writer fails (last matrix column), and going back would need the column re-added and filled from `product_id`. So we would keep `tickets.product_code` for at least one release after the last reader moves, and drop it only once the lecture 2 tests have been rewritten.

### Changing a product id

A UUID default only affects new rows ([`product_id_immutability.sql`](../../../database/postgres/experiments/lecture04/product_id_immutability.sql), rolled back):

```text
== 1. Changing the id of a product that tickets reference
ERROR:  23503: update or delete on table "products" violates foreign key constraint "tickets_product_id_fk" on table "tickets"
== 2. Changing the id of a product that nothing references yet
INSERT 0 1
UPDATE 1
== 3. Column privileges: an application role that may edit the catalogue but not ids
UPDATE 1
ERROR:  42501: permission denied for table products
```

The foreign key protects ids that tickets already use, but a new product's id can still be changed before its first sale. The application should connect with a role that has `UPDATE` only on `name`, `price` and `currency`, as in case 3. Then no application code can change an id, whatever it tries.

## Large tables

`030` is fine for a catalogue with two products. On a much larger table:

- `set local lock_timeout = '3s'` makes the migration give up if it cannot get its lock within 3 s. Without it, an `alter table` waiting behind a long transaction also blocks every query that queues up behind the `alter table`.
- `add column` without a default only changes metadata. The `update ... set id = gen_random_uuid()` rewrites every row in one transaction, so on a large table it should run in batches. The same applies to `031` on `tickets`, which the `where product_id is null` condition makes easy to repeat in batches.
- `set not null` scans the whole table while holding an exclusive lock. Instead: add `check (id is not null) not valid`, `validate` it (a lock that still allows reads and writes), then `set not null`, which can use the validated check and skip the scan.
- `add constraint unique` builds its index while blocking writes. Instead: `create unique index concurrently`, then `add constraint … unique using index`.
- The foreign keys are added `not valid` in 030 and validated in 032. Adding them does not scan `tickets`, and validating uses a lock that lets normal reads and writes continue.

## Compared with a tool-generated migration

The project has no EF Core model. For the same change made in one step (a non-nullable `Guid ProductId` on `Ticket`, a `Guid Id` alternate key on `Product`, `ProductCode` removed), EF Core's conventions produce roughly:

```csharp
migrationBuilder.DropForeignKey(name: "tickets_product_fk", table: "tickets");
migrationBuilder.DropColumn(name: "product_code", table: "tickets");
migrationBuilder.AddColumn<Guid>(name: "id", table: "products", type: "uuid",
    nullable: false, defaultValue: new Guid("00000000-0000-0000-0000-000000000000"));
migrationBuilder.AddUniqueConstraint(name: "AK_products_id", table: "products", column: "id");
migrationBuilder.AddColumn<Guid>(name: "product_id", table: "tickets", type: "uuid",
    nullable: false, defaultValue: new Guid("00000000-0000-0000-0000-000000000000"));
migrationBuilder.CreateIndex(name: "IX_tickets_product_id", table: "tickets", column: "product_id");
migrationBuilder.AddForeignKey(name: "FK_tickets_products_product_id", table: "tickets",
    column: "product_id", principalTable: "products", principalColumn: "id",
    onDelete: ReferentialAction.Cascade);
```

What the tool can work out from the model: the final shape, meaning columns, types, the unique key, the foreign key and an index on it.

What it cannot work out, because it depends on the existing data and on the order of the change:

- It drops `product_code` in the same step, before anything could copy the codes into ids. That is the unsafe change from section 2.
- Existing rows get the empty GUID. On `products`, that breaks the unique key as soon as there are two products. On `tickets`, it makes the foreign key fail.
- There is no backfill from code to id. It has to be written by hand (`migrationBuilder.Sql(...)`).
- There is no overlap phase, no `not valid`, no validation step and no lock timeout.
- A required relationship defaults to `onDelete: Cascade`. Deleting a product would delete its tickets, which is the opposite of the lecture 2 `on delete restrict` rule.

`dotnet ef migrations script --idempotent` only guards each migration with a history check. It does not make a destructive step safe to run on a populated database.
