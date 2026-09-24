# Lecture 2: Make invalid states difficult to store

| What | File |
| --- | --- |
| Constraint migration | [migrations/011_ticketing_integrity.sql](migrations/011_ticketing_integrity.sql) |
| Tests | [tests/011_ticketing_integrity_test.sql](tests/011_ticketing_integrity_test.sql) |
| The teacher's invalid writes | [experiments/constraints_should_fail.sql](experiments/constraints_should_fail.sql) |
| Integrity map, issue register, state-transition trace | [integrity-map.md](integrity-map.md) |
| Starter schema and seed (unchanged) | [init/](init/) |

## Reproduce

```bash
sh scripts/db-reset.sh 011
docker compose exec -T postgres psql -U mobility -d mobility -v ON_ERROR_STOP=1 < lecture02/tests/011_ticketing_integrity_test.sql
docker compose exec -T postgres psql -U mobility -d mobility < lecture02/experiments/constraints_should_fail.sql
```

To run the invalid writes against the schema without our constraints, rolled back:

```bash
sh scripts/db-reset.sh 000
{ echo 'begin;'; cat lecture02/experiments/constraints_should_fail.sql; echo 'rollback;'; } | docker compose exec -T postgres psql -U mobility -d mobility
```

## Invariants

The [integrity map](integrity-map.md) lists 18 rules, sorted into the lab's four groups:

- Column or table constraint: #1–#9
- Unique rule: #10–#13
- Depends on several rows or an outside system: #14–#16
- Needs a business decision: #17–#18

## Before and after

The starter schema accepted all 10 of the teacher's invalid writes. After the migration, each one is rejected by a named constraint:

```text
ERROR:  new row for relation "trips" violates check constraint "trips_capacity_non_negative"
ERROR:  new row for relation "trips" violates check constraint "trips_reserved_seats_within_capacity"
ERROR:  insert or update on table "tickets" violates foreign key constraint "tickets_trip_fk"
ERROR:  new row for relation "tickets" violates check constraint "tickets_validity_window"
ERROR:  duplicate key value violates unique constraint "tickets_ticket_code_unique"
ERROR:  new row for relation "tickets" violates check constraint "tickets_status_known"
ERROR:  new row for relation "products" violates check constraint "products_price_non_negative"
ERROR:  insert or update on table "payments" violates foreign key constraint "payments_ticket_fk"
ERROR:  duplicate key value violates unique constraint "payments_captured_reference_unique"
ERROR:  insert or update on table "validations" violates foreign key constraint "validations_ticket_fk"
```

## Tests

53 checks run in one transaction that is rolled back at the end. Each rejected write must fail with the right SQLSTATE and constraint name. GAP lines are writes the schema still accepts. On the schema without the migration, the file stops at its first rule with exit code 3.

<details>
<summary>Test output</summary>

```text
== Trips
PASS  capacity of zero -> accepted
PASS  reserved seats equal to capacity -> accepted
PASS  cancel a trip -> accepted
PASS  negative capacity -> 23514 trips_capacity_non_negative
PASS  more reserved seats than capacity -> 23514 trips_reserved_seats_within_capacity
PASS  negative reserved seats -> 23514 trips_reserved_seats_within_capacity
PASS  missing capacity -> 23502 capacity
PASS  missing reserved seats -> 23502 reserved_seats
PASS  unknown trip status -> 23514 trips_status_known
== Products
PASS  product with price and ISO currency -> accepted
PASS  negative product price -> 23514 products_price_non_negative
PASS  missing product price -> 23502 price
PASS  lower-case currency -> 23514 products_currency_iso_format
PASS  missing product currency -> 23502 currency
== Users
PASS  new user -> accepted
PASS  e-mail that differs only in letter case -> 23505 users_email_lower_unique
PASS  missing e-mail -> 23502 email
== Tickets
PASS  valid ticket -> accepted
PASS  ticket for an unknown trip -> 23503 tickets_trip_fk
PASS  ticket for an unknown user -> 23503 tickets_user_fk
PASS  ticket for an unknown product -> 23503 tickets_product_fk
PASS  validity window that ends before it starts -> 23514 tickets_validity_window
PASS  duplicate ticket code -> 23505 tickets_ticket_code_unique
PASS  unknown ticket status -> 23514 tickets_status_known
PASS  negative ticket price -> 23514 tickets_price_non_negative
PASS  two-letter ticket currency -> 23514 tickets_currency_iso_format
PASS  missing ticket code -> 23502 ticket_code
== Payments
PASS  pending payment before the gateway returns a reference -> accepted
PASS  captured payment with a new reference -> accepted
PASS  payment for an unknown ticket -> 23503 payments_ticket_fk
PASS  payment by an unknown user -> 23503 payments_user_fk
PASS  lower-case payment currency -> 23514 payments_currency_iso_format
PASS  negative payment amount -> 23514 payments_amount_non_negative
PASS  unknown payment status -> 23514 payments_status_known
PASS  captured payment without a gateway reference -> 23514 payments_captured_has_reference
PASS  same capture recorded twice -> 23505 payments_captured_reference_unique
PASS  refund updates the captured row -> accepted
PASS  capture delivered again after it was refunded -> 23505 payments_captured_reference_unique
PASS  failed attempt that reuses a captured reference (outside the index by design) -> accepted
== Deletes that would erase history
PASS  delete a ticket that has a payment -> 23503 payments_ticket_fk
PASS  delete a product that tickets were sold for -> 23503 tickets_product_fk
== Validations
PASS  validation whose code belongs to the ticket -> accepted
PASS  ticket id combined with the code of another ticket -> 23503 validations_ticket_fk
PASS  validation for an unknown ticket -> 23503 validations_ticket_fk
PASS  validation at an unknown stop -> 23503 validations_stop_fk
PASS  unknown validation result -> 23514 validations_result_known
PASS  validation without the scanned code -> 23502 ticket_code
== Boundaries: rules a constraint does not cover
GAP   seat counter no longer matches the tickets sold -> accepted, not protected by a constraint
GAP   price of a sold ticket rewritten afterwards -> accepted, not protected by a constraint
GAP   captured amount differs from the ticket price -> accepted, not protected by a constraint
GAP   accepted validation outside the ticket validity window -> accepted, not protected by a constraint
PASS  disable a user -> accepted
GAP   disabled user buys a ticket -> accepted, not protected by a constraint
All checks passed. Every change was rolled back.
```

</details>

## Rules a constraint cannot solve

Kept for the transactions lecture:

1. **The last seat.** Two purchases both read `reserved_seats = capacity - 1` and both write `capacity`. Each row passes the check, which never sees the other transaction.
2. **The payment gateway.** The capture happens outside the database, so no constraint can make "money captured" and "ticket and payment stored" happen together. The unique capture reference (#12) only makes a retry safe to repeat.

## Delete and update behaviour

| Rows | On delete | Updates that change history |
| --- | --- | --- |
| Tickets, payments, validations | Restrict. They are history, kept under a retention policy | A sold ticket's price or a captured amount should never change. Not enforced yet (GAP tests) |
| Users | Restrict. Users are disabled with `is_disabled`, not deleted | – |
| Trips, products, stops | Restrict. Trips are cancelled and products and stops retired | Catalogue prices may change, because each ticket keeps its own price |
