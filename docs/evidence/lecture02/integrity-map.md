# Integrity map

Which layer owns each rule after [`011_ticketing_integrity.sql`](../../../database/postgres/migrations/011_ticketing_integrity.sql). Test names refer to [`011_ticketing_integrity_test.sql`](../../../database/postgres/tests/011_ticketing_integrity_test.sql). The kind of each rule (1–4) is explained in the [lecture 2 evidence](README.md#invariants-and-how-they-are-classified).

| # | Invariant | Affected tables and columns | Current protection | Missing protection or limitation | Expected failure behaviour | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Trip capacity is present and not negative | `trips.capacity` | Database: `NOT NULL`, `trips_capacity_non_negative` | – | `23502` / `23514` | Accepted: "capacity of zero". Rejected: "negative capacity", "missing capacity" |
| 2 | Reserved seats are between 0 and capacity | `trips.reserved_seats`, `trips.capacity` | Database: `NOT NULL`, `trips_reserved_seats_within_capacity` | Checks one row only. Says nothing about concurrent purchases (#17) or about the tickets actually sold (#18) | `23514` / `23502` | Accepted: "reserved seats equal to capacity". Rejected: "more reserved seats than capacity", "negative reserved seats", "missing reserved seats" |
| 3 | Trip status is `Scheduled`, `Cancelled` or `Completed` | `trips.status` | Database: `trips_status_known` | The set is our decision. A delay is treated as real-time information, not a status | `23514` | Accepted: "cancel a trip". Rejected: "unknown trip status" |
| 4 | Product price is present and not negative | `products.price` | Database: `NOT NULL`, `products_price_non_negative` | The number of decimals is not limited. That is a domain decision (DKK uses two) | `23514` / `23502` | Accepted: "product with price and ISO currency". Rejected: "negative product price", "missing product price" |
| 5 | Ticket price and payment amount are not negative | `tickets.price`, `payments.amount` | Database: `tickets_price_non_negative`, `payments_amount_non_negative` | Amount is not tied to the ticket price (#20) | `23514` | Accepted: "valid ticket", "captured payment with a new reference". Rejected: "negative ticket price", "negative payment amount" |
| 6 | Currency is present and written as three upper-case letters | `products.currency`, `tickets.currency`, `payments.currency` | Database: `NOT NULL`, `*_currency_iso_format` | Checks the format only: `XYZ` passes. Ticket and payment currency may differ | `23514` / `23502` | Accepted: "product with price and ISO currency", "valid ticket", "captured payment with a new reference". Rejected: "lower-case currency", "two-letter ticket currency", "lower-case payment currency", "missing product currency" |
| 7 | Ticket validity does not end before it starts | `tickets.valid_from_utc`, `tickets.valid_to_utc` | Database: `NOT NULL`, `tickets_validity_window` | The window is not compared with the trip departure | `23514` | Accepted: "valid ticket". Rejected: "validity window that ends before it starts" |
| 8 | Status and result values come from known sets | `tickets.status`, `payments.status`, `validations.result` | Database: `tickets_status_known`, `payments_status_known`, `validations_result_known` | Which transitions are allowed is not enforced (#24) | `23514` | Accepted: "valid ticket", "pending payment before the gateway returns a reference", "refund updates the captured row", "validation whose code belongs to the ticket". Rejected: "unknown ticket status", "unknown payment status", "unknown validation result" |
| 9 | A ticket refers to an existing user, trip and product | `tickets.user_id`, `trip_id`, `product_code` | Database: `NOT NULL`, `tickets_user_fk`, `tickets_trip_fk`, `tickets_product_fk` | – | `23503` | Accepted: "valid ticket". Rejected: "ticket for an unknown trip / user / product" |
| 10 | A payment refers to an existing ticket and user | `payments.ticket_id`, `payments.user_id` | Database: `NOT NULL`, `payments_ticket_fk`, `payments_user_fk` | Payer and ticket holder may be different users (#26) | `23503` | Accepted: "captured payment with a new reference". Rejected: "payment for an unknown ticket", "payment by an unknown user" |
| 11 | A validation refers to an existing ticket, and to an existing stop when one is recorded | `validations.ticket_id`, `ticket_code`, `stop_id` | Database: `NOT NULL`, `validations_ticket_fk`, `validations_stop_fk` | Vehicles and devices have no table (#22). Scans of unknown codes cannot be stored (#25) | `23503` | Accepted: "validation whose code belongs to the ticket". Rejected: "validation for an unknown ticket", "validation at an unknown stop" |
| 12 | A captured or refunded payment has a gateway reference | `payments.status`, `external_payment_reference` | Database: `payments_captured_has_reference` | Reference format is not checked | `23514` | Accepted: "captured payment with a new reference", "pending payment before the gateway returns a reference". Rejected: "captured payment without a gateway reference" |
| 13 | Ticket codes allow unambiguous lookup | `tickets.ticket_code` | Database: `NOT NULL`, `tickets_ticket_code_unique` | Case variants would count as different codes. Codes are generated in upper case | `23505` / `23502` | Accepted: "valid ticket". Rejected: "duplicate ticket code", "missing ticket code" |
| 14 | A validation's ticket id and code belong to the same ticket | `validations.(ticket_id, ticket_code)` → `tickets.(id, ticket_code)` | Database: `tickets_id_ticket_code_unique` + composite `validations_ticket_fk` | – | `23503` | Accepted: "validation whose code belongs to the ticket". Rejected: "ticket id combined with the code of another ticket" |
| 15 | One gateway capture is recorded once | `payments.external_payment_reference` where status is `Captured`/`Refunded` | Database: partial unique index `payments_captured_reference_unique` | Failed and pending attempts may repeat a reference (decision, see README) | `23505` | Accepted: "captured payment with a new reference", "failed attempt that reuses a captured reference". Rejected: "same capture recorded twice", "capture delivered again after it was refunded" |
| 16 | One account per e-mail address | `users.email` | Database: `NOT NULL`, unique index `users_email_lower_unique` on `lower(email)` | Assumes an e-mail address identifies one account | `23505` / `23502` | Accepted: "new user". Rejected: "e-mail that differs only in letter case", "missing e-mail" |
| 17 | Two purchases cannot both take the last seat | `trips.reserved_seats`, `tickets` | None yet. Belongs to the purchase transaction (transactions lecture) | A row check cannot see a competing transaction | Silent: both purchases succeed | lab boundary, not tested here |
| 18 | The seat counter equals the tickets that hold a seat | `trips.reserved_seats`, `tickets.trip_id`, `tickets.status` | None | A stored copy of a count. The seed data already disagrees | Silent | [`seat_counter_drift.sql`](../../../database/postgres/experiments/lecture02/seat_counter_drift.sql), GAP "seat counter no longer matches the tickets sold" |
| 19 | Ticket, payment and seat change happen together and agree with the gateway | `tickets`, `payments`, `trips` + payment gateway | Application and transaction design (later lecture) | One step happens in an external system | Partial purchase | state-transition trace below |
| 20 | The captured amount matches the ticket price | `payments.amount/currency` vs `tickets.price/currency` | Application (planned) | Cross-row. Unclear whether partial payments exist | Silent | GAP "captured amount differs from the ticket price" |
| 21 | An accepted validation needs a usable ticket at scan time | `validations` vs `tickets.status`, `valid_from_utc`, `valid_to_utc` | Validator application | Depends on another row and on the time of the scan | Silent | GAP "accepted validation outside the ticket validity window" |
| 22 | Vehicles and devices are known | `validations.vehicle_id`, `device_id` | None: no registry table | External register | Silent | – |
| 23 | Disabled users cannot buy tickets | `users.is_disabled`, `tickets` | Undecided | Domain or transaction policy | Silent | GAP "disabled user buys a ticket" |
| 24 | Status changes follow allowed transitions | `tickets.status`, `payments.status` | Undecided | Needs a trigger or application rule | Silent | – |
| 25 | Rejected scans of unknown codes are recorded | `validations` | Undecided | `NOT NULL` and the composite key forbid it today | Scan cannot be logged | – |
| 26 | Only the ticket holder pays for a ticket | `payments.user_id` vs `tickets.user_id` | Undecided (gift purchases?) | Cross-row | Silent | – |
| 27 | A sold ticket keeps its agreed price | `tickets.price`, `tickets.currency` | None. Needs a trigger or column privileges | An `UPDATE` is allowed | Silent | GAP "price of a sold ticket rewritten afterwards" |
| 28 | A day pass is not bound to one trip | `tickets.trip_id` (required) vs product `DAY` | Undecided | `TICKET-3` is a day pass tied to `TRIP-M2-20260429-1200` | – | seed data |

## Issue register

### Issue 1

- Evidence: [`seat_counter_drift.sql`](../../../database/postgres/experiments/lecture02/seat_counter_drift.sql) on the reset database: `TRIP-M2-20260429-0800` stores `reserved_seats = 2` but has one seat-holding ticket, and `TRIP-M2-20260429-1200` stores `0` but has `TICKET-3`.
- Problem: `reserved_seats` is a stored count that no rule connects to `tickets`. `trips_reserved_seats_within_capacity` only compares two columns in the same row.
- Consequence: availability shown to customers and the sell/no-sell decision can both be wrong, even though every row passes its constraints.
- Specific improvement: change the counter in the same transaction as the ticket insert, with a conditional update (`... set reserved_seats = reserved_seats + 1 where id = $1 and reserved_seats < capacity`), and add a reconciliation query to the reports.
- Open question: is `reserved_seats` a cache of the ticket count or its own fact (for example seats held by group bookings)? That decides whether it should be derived or stored.

### Issue 2

- Evidence: tests "validation for an unknown ticket" (rejected) and the validation trace below.
- Problem: `validations.ticket_id` and `ticket_code` are required and must match an existing ticket, so the table cannot record a scan of a code that does not exist.
- Consequence: forged or mistyped codes leave no trace, which matters for fraud follow-up and device diagnostics.
- Specific improvement: keep `validations` for scans of known tickets and store unknown-code scans in a separate log table without the foreign key.
- Open question: does the operator need unknown-code scans at all, and for how long?

## State-transition trace

### Ticket purchase

1. Read the `trips` row: it must exist, have `status = 'Scheduled'` and `reserved_seats < capacity`. Read the `products` row for the current price and currency. Read the `users` row: it must exist (and `is_disabled` may matter, #23).
2. The payment gateway captures the amount outside the database and returns an external reference.
3. Insert the `tickets` row with a new `ticket_code`, `status = 'Active'`, the validity window and the agreed price and currency. `tickets_user_fk`, `tickets_trip_fk` and `tickets_product_fk` require the rows from step 1. `tickets_ticket_code_unique` and the check constraints run here.
4. Insert the `payments` row with `status = 'Captured'` and the gateway reference. `payments_ticket_fk` requires the ticket from step 3, so this order is forced. `payments_captured_has_reference` and `payments_captured_reference_unique` run here.
5. Update `trips.reserved_seats` by one. `trips_reserved_seats_within_capacity` runs here.
6. The customer sees the ticket.

If steps 3–5 are not one transaction, a ticket can exist without a payment row or a seat can go uncounted. The capture in step 2 can never be part of that transaction (#19). Concurrency is left for the transactions lecture.

### Ticket validation

1. Look up `tickets` by `ticket_code`. `tickets_ticket_code_unique` guarantees zero or one row.
2. The validator decides the result: `status` in (`Active`, `Validated`), scan time between `valid_from_utc` and `valid_to_utc`, and the vehicle's route should match the ticket (#21, application rule).
3. Insert the `validations` row using the ticket's own `id` and `ticket_code`. The composite `validations_ticket_fk` rejects a pair that belongs to two tickets, and `validations_stop_fk` checks the stop.
4. Optionally update `tickets.status` from `Active` to `Validated` (`tickets_status_known`).

Reporting tables are not touched on this path. If step 1 finds nothing, step 3 cannot be written (Issue 2).
