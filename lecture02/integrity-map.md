# Integrity map

Which layer owns each rule after [`011_ticketing_integrity.sql`](migrations/011_ticketing_integrity.sql). Evidence names are tests in [`011_ticketing_integrity_test.sql`](tests/011_ticketing_integrity_test.sql).

| # | Invariant | Tables and columns | Current protection | Missing protection or limitation | Expected failure | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Capacity is present and not negative | `trips.capacity` | Database: `NOT NULL`, `trips_capacity_non_negative` | – | `23502` / `23514` | Accepted: "capacity of zero". Rejected: "negative capacity", "missing capacity" |
| 2 | Reserved seats are between 0 and capacity | `trips.reserved_seats` | Database: `NOT NULL`, `trips_reserved_seats_within_capacity` | Checks one row only (#14, #15) | `23514` / `23502` | Accepted: "reserved seats equal to capacity". Rejected: "more reserved seats than capacity", "negative reserved seats", "missing reserved seats" |
| 3 | Prices and amounts are present and not negative | `products.price`, `tickets.price`, `payments.amount` | Database: `NOT NULL`, `products_price_non_negative`, `tickets_price_non_negative`, `payments_amount_non_negative` | The amount is not tied to the ticket price (GAP test) | `23514` / `23502` | Accepted: "product with price and ISO currency", "valid ticket". Rejected: "negative product price", "missing product price", "negative ticket price", "negative payment amount" |
| 4 | Currency is present and written as three capital letters | `currency` on products, tickets, payments | Database: `NOT NULL`, `*_currency_iso_format` | Checks the format only | `23514` / `23502` | Accepted: "valid ticket". Rejected: "lower-case currency", "two-letter ticket currency", "lower-case payment currency", "missing product currency" |
| 5 | Validity does not end before it starts | `tickets.valid_from_utc`, `valid_to_utc` | Database: `NOT NULL`, `tickets_validity_window` | Not compared with the trip | `23514` | Accepted: "valid ticket". Rejected: "validity window that ends before it starts" |
| 6 | Status values come from known sets | `status` on trips, tickets, payments; `validations.result` | Database: `trips_status_known`, `tickets_status_known`, `payments_status_known`, `validations_result_known` | Allowed transitions are not enforced | `23514` | Accepted: "cancel a trip", "refund updates the captured row". Rejected: "unknown trip status", "unknown ticket status", "unknown payment status", "unknown validation result" |
| 7 | A ticket refers to an existing user, trip and product | `tickets.user_id`, `trip_id`, `product_code` | Database: `NOT NULL`, `tickets_user_fk`, `tickets_trip_fk`, `tickets_product_fk` | – | `23503` | Accepted: "valid ticket". Rejected: "ticket for an unknown trip / user / product" |
| 8 | A payment refers to an existing ticket and user | `payments.ticket_id`, `user_id` | Database: `NOT NULL`, `payments_ticket_fk`, `payments_user_fk` | The payer may differ from the ticket holder | `23503` | Accepted: "captured payment with a new reference". Rejected: "payment for an unknown ticket", "payment by an unknown user" |
| 9 | A validation refers to an existing ticket, and to an existing stop | `validations.ticket_id`, `stop_id` | Database: `NOT NULL`, `validations_ticket_fk`, `validations_stop_fk` | A scan outside the validity window is accepted (GAP test) | `23503` | Accepted: "validation whose code belongs to the ticket". Rejected: "validation for an unknown ticket", "validation at an unknown stop" |
| 10 | Ticket codes allow unambiguous lookup | `tickets.ticket_code` | Database: `NOT NULL`, `tickets_ticket_code_unique` | – | `23505` / `23502` | Accepted: "valid ticket". Rejected: "duplicate ticket code", "missing ticket code" |
| 11 | A validation's ticket id and code belong to the same ticket | `validations (ticket_id, ticket_code)` | Database: `tickets_id_ticket_code_unique` and the composite `validations_ticket_fk` | – | `23503` | Accepted: "validation whose code belongs to the ticket". Rejected: "ticket id combined with the code of another ticket" |
| 12 | A gateway capture is recorded once | `payments.external_payment_reference`, `status` | Database: partial unique index `payments_captured_reference_unique`, `payments_captured_has_reference` | Failed attempts may repeat a reference (our decision) | `23505` / `23514` | Accepted: "captured payment with a new reference", "failed attempt that reuses a captured reference". Rejected: "same capture recorded twice", "capture delivered again after it was refunded", "captured payment without a gateway reference" |
| 13 | One account per e-mail address | `users.email` | Database: `NOT NULL`, `users_email_lower_unique` on `lower(email)` | – | `23505` / `23502` | Accepted: "new user". Rejected: "e-mail that differs only in letter case", "missing e-mail" |
| 14 | Two purchases cannot both take the last seat | `trips.reserved_seats`, `tickets` | None yet: belongs in the purchase transaction | A row check cannot see the other transaction | Silent oversell | Lab boundary |
| 15 | The seat count matches the tickets that hold a seat | `trips.reserved_seats`, `tickets` | None | It is a stored count | Silent | GAP "seat counter no longer matches the tickets sold", Issue 1 |
| 16 | Ticket, payment and seat count change together, in step with the gateway | `tickets`, `payments`, `trips`, payment gateway | Application and transaction design (later lecture) | The gateway is outside the database | Half-finished purchase | Purchase trace below |
| 17 | Disabled users cannot buy tickets | `users.is_disabled`, `tickets` | Undecided | Needs a business decision | Silent | GAP "disabled user buys a ticket" |
| 18 | Scans of unknown codes are recorded | `validations` | Undecided | `NOT NULL` and the key forbid it today | The scan is lost | Issue 2 |

Groups: #1–#9 are column or table constraints, #10–#13 unique rules, #14–#16 depend on several rows or an outside system, and #17–#18 need a business decision.

## Issue register

### Issue 1

- Evidence: in the seed, `TRIP-M2-20260429-0800` has `reserved_seats = 2` but only one ticket, `TICKET-1`. The GAP test shows the counter can be changed freely.
- Problem: `reserved_seats` is a stored count that nothing ties to `tickets`.
- Consequence: seats shown to customers, and the decision to sell, can both be wrong.
- Specific improvement: update the count in the purchase transaction with `set reserved_seats = reserved_seats + 1 where id = $1 and reserved_seats < capacity`.
- Open question: is the count a copy of the tickets, or its own fact, for example seats held for groups?

### Issue 2

- Evidence: test "validation for an unknown ticket" is rejected.
- Problem: a validation must name an existing ticket, so a scan of an unknown code cannot be stored.
- Consequence: forged or mistyped codes leave no trace.
- Specific improvement: log unknown-code scans in a separate table without the foreign key.
- Open question: does the operator need them, and for how long?

## State-transition trace

### Ticket purchase

1. Read the `trips` row (it must be `Scheduled` and have `reserved_seats < capacity`), the `products` row and the `users` row.
2. The payment gateway captures the amount and returns a reference.
3. Insert `tickets`. The user, trip and product must exist (#7), and the code must be unique (#10).
4. Insert `payments`. The ticket from step 3 must exist (#8), and the reference is checked (#12).
5. Update `trips.reserved_seats` (#2).

If steps 3–5 are not one transaction, a ticket can exist without a payment, or a seat can go uncounted (#16).

### Ticket validation

1. Find the ticket by `ticket_code` (#10): zero or one row.
2. Decide the result: the ticket is `Active` or `Validated`, and the scan is inside the validity window.
3. Insert `validations` with the ticket's own id and code (#11), and the stop (#9).
4. Optionally set the ticket to `Validated`.
