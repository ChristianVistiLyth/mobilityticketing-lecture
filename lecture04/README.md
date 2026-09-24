# Lecture 4: Change product identity without breaking tickets

Tickets now refer to products by a stable `product_id` instead of `product_code`, without breaking old or new application code on the way. Every ticket keeps its product, price and currency.

| Step | File |
| --- | --- |
| Expand | [migrations/030_expand_product_identity.sql](migrations/030_expand_product_identity.sql) |
| Backfill (repeatable) | [migrations/031_backfill_ticket_product.sql](migrations/031_backfill_ticket_product.sql) |
| Require `product_id` | [migrations/032_require_ticket_product.sql](migrations/032_require_ticket_product.sql) |
| Remove `product_code` (rehearsal, rolled back) | [experiments/remove_legacy.sql](experiments/remove_legacy.sql) |
| Readers and writers, checks | [experiments/](experiments/) |

## Reproduce

```bash
sh lecture04/experiments/run_lab.sh
```

The script resets the database to the lecture 3 state and runs every step below in order. It stops if anything unexpected happens, including an expected failure that fails with the wrong error. The outputs here are from one run, and product ids are random on each run.

## 1. Baseline

```text
    id    | product_code | price | currency
----------+--------------+-------+----------
 TICKET-1 | SINGLE       | 36.00 | DKK
 TICKET-2 | SINGLE       | 36.00 | DKK
 TICKET-3 | DAY          | 65.00 | DKK
```

Every ticket's code resolves to a product. `TICKET-3` was bought for 65 DKK, although the catalogue now says 80. Before starting, [product_code_dependents.sql](experiments/product_code_dependents.sql) found no views or functions from lecture 3 that use `tickets.product_code`.

## 2. The unsafe change

**Prediction.** Dropping `product_code` works, and silently removes its foreign key. Adding a required `product_id` fails, because existing tickets have no value. A random default fails the foreign key. The old reader and writer break.

**Result** ([unsafe_change.sql](experiments/unsafe_change.sql), rolled back):

```text
ERROR:  23502: column "product_id" of relation "tickets" contains null values
ERROR:  23503: insert or update on table "tickets" violates foreign key constraint "tickets_product_id_fkey"
ERROR:  42703: column "product_code" does not exist
```

**Why it is unsafe.** Existing tickets could only get their `product_id` from `product_code`, and that is exactly what gets dropped first. Afterwards nothing links a ticket to its product, and not even the price does, because TICKET-3 paid 65, not 80. Code that still uses `product_code` breaks at once, and every application instance cannot switch at the same moment.

## 3. Expand

030 gives `products` a UUID `id`, backfilled, unique and required. It adds a nullable `tickets.product_id` with a foreign key marked `not valid`. We also added `tickets_product_pair_fk` on `(product_id, product_code)`, so the two references can never name different products. A null `product_id` skips that check, so old writers keep working.

`lock_timeout = '3s'` makes the migration give up rather than queue behind a long transaction and block every query that arrives after it. See [Large tables](#large-tables).

## 4. Both versions side by side

| Script | Before expansion | After expansion | After backfill | `product_id` required | `product_code` dropped |
| --- | --- | --- | --- | --- | --- |
| `old_writer` | works | works | works | **fails** | fails |
| `old_reader` | works | works | works | works | fails |
| `new_writer` | fails | works | works | works | fails |
| `new_reader` | fails | works | works | works | fails |
| `final_writer` | fails | fails | fails | fails | works |
| `final_reader` | fails | **runs, but returns 0 of 3 tickets** | works | works | works |

- **A query that runs but misses tickets.** Before the backfill, `final_reader` only follows `product_id`, which is still empty. `new_reader` falls back to the code and resolves all three tickets.
- **The final writer waits for the drop.** It fails until `product_code` is dropped, because lecture 2 made that column `NOT NULL`. That keeps codes on every ticket while old readers might still exist.
- **The new writer** takes a product id and the agreed price, and looks up the code itself. The caller never supplies a code, so it cannot conflict. An unknown id is rejected (`23502`, no code found).
- **A mismatched pair written directly in SQL** ([mismatch_test.sql](experiments/mismatch_test.sql)) is rejected by `tickets_product_pair_fk`. With only the single-column foreign keys, the database accepts it and only `verify.sql` catches it. The writer preventing a mismatch and the database preventing it are two different guarantees.

## 5. Backfill, twice

```text
UPDATE 3
UPDATE 0
```

The second run changes nothing, because 031 only touches tickets with no `product_id`.

## 6. A late ticket from an old writer

The old writer adds `LAB04-LATE-1` after the backfill. [verify.sql](experiments/verify.sql) lists it, the backfill fills it in (`UPDATE 1`), and `verify.sql` then returns no rows. Ids that were already set do not change.

## 7. Require the new reference

With another old-writer ticket still missing its id, 032 fails and nothing changes:

```text
ERROR:  23502: column "product_id" of relation "tickets" contains null values
```

After one more backfill and an empty `verify.sql`, 032 commits. From then on the old writer fails with `23502`.

## 8. Remove the old column (rehearsal)

Before dropping, we checked what still uses `tickets.product_code`:

- **Views and functions:** none ([product_code_dependents.sql](experiments/product_code_dependents.sql)).
- **The column's own foreign keys:** they are dropped together with it.
- **Repository files:** the lecture 2 migration, its tests and the teacher's invalid writes. The tests would need rewriting before a real drop.

[remove_legacy.sql](experiments/remove_legacy.sql) shows that `drop column` without `CASCADE` stops at a view that still needs the column (`2BP01`). With nothing depending on it, the drop goes through. It is rolled back, and `products.code` stays.

## 9. Prices and currencies

At the end, `verify.sql` finds no missing or mismatched references and no changed tickets:

```text
      id      |              product_id              | product_code | price | currency
--------------+--------------------------------------+--------------+-------+----------
 LAB04-LATE-1 | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 LAB04-LATE-2 | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 TICKET-1     | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 TICKET-2     | 039016bb-8443-4e08-9f7c-a818af298a0b | SINGLE       | 36.00 | DKK
 TICKET-3     | 9a9f0765-bda1-4bdb-8400-c86ca1a8aa48 | DAY          | 65.00 | DKK
```

## Rollout decision

- **When to stop the old writers:** before 032. Section 7 shows 032 refusing to run while an old-writer ticket still lacks an id. We would also need to know from deployment which versions are running, because the repository cannot tell us.
- **Could we go back to the old version?** Until the column is dropped, yes: undoing 032's `NOT NULL` makes the old writer work again, and every ticket still has its code. After the drop there is no quick way back. We would keep `product_code` for at least one release after the last reader moves.
- **Changing a product id:** the foreign key already blocks changing an id that tickets use. For the rest, the application's database role should have `UPDATE` only on `name`, `price` and `currency`.

## Large tables

- The backfill `update` statements should run in batches. 031 is easy to repeat, because it only touches null references.
- `set not null` scans the whole table under a lock. Instead, add `check (id is not null) not valid`, validate it, and then `set not null`, which skips the scan.
- A unique constraint builds its index while blocking writes. Instead, use `create unique index concurrently` and then `add constraint … unique using index`.
- The foreign keys are added `not valid` and validated in 032, which does not block normal reads and writes.

## Compared with an EF Core migration

We don't use EF Core. For the same change made in one step, EF Core would generate roughly:

```csharp
migrationBuilder.DropColumn(name: "product_code", table: "tickets");
migrationBuilder.AddColumn<Guid>(name: "product_id", table: "tickets", nullable: false,
    defaultValue: new Guid("00000000-0000-0000-0000-000000000000"));
migrationBuilder.AddForeignKey(name: "FK_tickets_products_product_id", table: "tickets",
    column: "product_id", principalTable: "products", principalColumn: "id",
    onDelete: ReferentialAction.Cascade);
```

The tool can work out the final shape from the model. It cannot work out the order or the data. It drops the code before copying it, fills existing rows with the empty GUID so the foreign key fails, has no backfill and no overlap phase, and defaults to a cascading delete.
