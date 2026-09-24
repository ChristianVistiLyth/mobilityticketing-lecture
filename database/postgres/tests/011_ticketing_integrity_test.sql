-- Tests for migrations/011_ticketing_integrity.sql.
--
--   docker compose exec -T postgres psql -U mobility -d mobility -v ON_ERROR_STOP=1 < database/postgres/tests/011_ticketing_integrity_test.sql
--
-- Each rejected write asserts the SQLSTATE and the constraint (or, for NOT NULL,
-- the column) that stopped it. GAP lines are writes the schema still accepts:
-- rules that need more than a constraint. Everything runs in one transaction and
-- is rolled back, so the file can be run again. A FAIL stops psql with exit code 3.

\set QUIET on
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

begin;

do $$
begin
    if exists (
        select 1 from information_schema.columns
        where table_name = 'tickets' and column_name = 'product_id' and is_nullable = 'NO'
    ) then
        raise exception 'These tests write tickets by product_code only. Run them at migration level 011-031 (sh scripts/db-reset.sh 022).';
    end if;
end $$;

create function pg_temp.accepts(test_name text, statement text)
returns text
language plpgsql
as $$
begin
    execute statement;
    return 'PASS  ' || test_name || ' -> accepted';
exception when others then
    raise exception 'FAIL  % -> expected success, got % %', test_name, sqlstate, sqlerrm;
end;
$$;

create function pg_temp.rejects(test_name text, statement text, expected_sqlstate text, expected_object text)
returns text
language plpgsql
as $$
declare
    violated_constraint text;
    violated_column text;
begin
    begin
        execute statement;
    exception when others then
        get stacked diagnostics
            violated_constraint = constraint_name,
            violated_column = column_name;
        -- NOT NULL is matched on the column: PostgreSQL 18 also names the constraint.
        if sqlstate = expected_sqlstate and expected_object in (violated_constraint, violated_column) then
            return format('PASS  %s -> %s %s', test_name, sqlstate, expected_object);
        end if;
        raise exception 'FAIL  % -> expected % %, got % constraint "%" column "%" (%)',
            test_name, expected_sqlstate, expected_object, sqlstate, violated_constraint, violated_column, sqlerrm;
    end;
    raise exception 'FAIL  % -> expected % %, but the write was accepted',
        test_name, expected_sqlstate, expected_object;
end;
$$;

create function pg_temp.gap(test_name text, statement text)
returns text
language plpgsql
as $$
begin
    execute statement;
    return 'GAP   ' || test_name || ' -> accepted, not protected by a constraint';
exception when others then
    raise exception 'FAIL  % -> documented gap is now rejected: % %', test_name, sqlstate, sqlerrm;
end;
$$;

\echo '== Trips'
select pg_temp.accepts('capacity of zero',
    $sql$update trips set capacity = 0 where id = 'TRIP-M2-20260429-1200'$sql$);
select pg_temp.accepts('reserved seats equal to capacity',
    $sql$update trips set reserved_seats = capacity where id = 'TRIP-5C-20260429-1700'$sql$);
select pg_temp.accepts('cancel a trip',
    $sql$update trips set status = 'Cancelled' where id = 'TRIP-5C-20260429-1700'$sql$);
select pg_temp.rejects('negative capacity',
    $sql$update trips set capacity = -1 where id = 'TRIP-M2-20260429-0800'$sql$,
    '23514', 'trips_capacity_non_negative');
select pg_temp.rejects('more reserved seats than capacity',
    $sql$update trips set reserved_seats = capacity + 1 where id = 'TRIP-M2-20260429-0800'$sql$,
    '23514', 'trips_reserved_seats_within_capacity');
select pg_temp.rejects('negative reserved seats',
    $sql$update trips set reserved_seats = -1 where id = 'TRIP-M2-20260429-0800'$sql$,
    '23514', 'trips_reserved_seats_within_capacity');
select pg_temp.rejects('missing capacity',
    $sql$update trips set capacity = null where id = 'TRIP-M2-20260429-0800'$sql$,
    '23502', 'capacity');
select pg_temp.rejects('missing reserved seats',
    $sql$update trips set reserved_seats = null where id = 'TRIP-M2-20260429-0800'$sql$,
    '23502', 'reserved_seats');
select pg_temp.rejects('unknown trip status',
    $sql$update trips set status = 'Delayed' where id = 'TRIP-M2-20260429-0800'$sql$,
    '23514', 'trips_status_known');

\echo '== Products'
select pg_temp.accepts('product with price and ISO currency',
    $sql$insert into products (code, name, price, currency) values ('CHILD', 'Child single trip', 18.00, 'DKK')$sql$);
select pg_temp.rejects('negative product price',
    $sql$update products set price = -1 where code = 'SINGLE'$sql$,
    '23514', 'products_price_non_negative');
select pg_temp.rejects('missing product price',
    $sql$update products set price = null where code = 'SINGLE'$sql$,
    '23502', 'price');
select pg_temp.rejects('lower-case currency',
    $sql$update products set currency = 'dkk' where code = 'SINGLE'$sql$,
    '23514', 'products_currency_iso_format');
select pg_temp.rejects('missing product currency',
    $sql$update products set currency = null where code = 'SINGLE'$sql$,
    '23502', 'currency');

\echo '== Users'
select pg_temp.accepts('new user',
    $sql$insert into users (id, email, full_name) values ('USER-3', 'carla@example.test', 'Carla Holm')$sql$);
select pg_temp.rejects('e-mail that differs only in letter case',
    $sql$insert into users (id, email, full_name) values ('USER-4', 'Anna@Example.test', 'Anna Again')$sql$,
    '23505', 'users_email_lower_unique');
select pg_temp.rejects('missing e-mail',
    $sql$insert into users (id, email, full_name) values ('USER-5', null, 'No Mail')$sql$,
    '23502', 'email');

\echo '== Tickets'
select pg_temp.accepts('valid ticket',
    $sql$insert into tickets (id, user_id, trip_id, ticket_code, status, product_code, valid_from_utc, valid_to_utc, price, currency)
         values ('T-TEST-1', 'USER-3', 'TRIP-M2-20260429-1200', 'CODE-TEST-1', 'Active', 'SINGLE',
                 '2026-04-29 11:45:00+00', '2026-04-29 14:00:00+00', 36.00, 'DKK')$sql$);
select pg_temp.rejects('ticket for an unknown trip',
    $sql$insert into tickets (id, user_id, trip_id, ticket_code, status, product_code, valid_from_utc, valid_to_utc, price, currency)
         values ('T-TEST-2', 'USER-3', 'TRIP-DOES-NOT-EXIST', 'CODE-TEST-2', 'Active', 'SINGLE',
                 '2026-04-29 11:45:00+00', '2026-04-29 14:00:00+00', 36.00, 'DKK')$sql$,
    '23503', 'tickets_trip_fk');
select pg_temp.rejects('ticket for an unknown user',
    $sql$insert into tickets (id, user_id, trip_id, ticket_code, status, product_code, valid_from_utc, valid_to_utc, price, currency)
         values ('T-TEST-2', 'USER-DOES-NOT-EXIST', 'TRIP-M2-20260429-1200', 'CODE-TEST-2', 'Active', 'SINGLE',
                 '2026-04-29 11:45:00+00', '2026-04-29 14:00:00+00', 36.00, 'DKK')$sql$,
    '23503', 'tickets_user_fk');
select pg_temp.rejects('ticket for an unknown product',
    $sql$insert into tickets (id, user_id, trip_id, ticket_code, status, product_code, valid_from_utc, valid_to_utc, price, currency)
         values ('T-TEST-2', 'USER-3', 'TRIP-M2-20260429-1200', 'CODE-TEST-2', 'Active', 'WEEK',
                 '2026-04-29 11:45:00+00', '2026-04-29 14:00:00+00', 36.00, 'DKK')$sql$,
    '23503', 'tickets_product_fk');
select pg_temp.rejects('validity window that ends before it starts',
    $sql$insert into tickets (id, user_id, trip_id, ticket_code, status, product_code, valid_from_utc, valid_to_utc, price, currency)
         values ('T-TEST-2', 'USER-3', 'TRIP-M2-20260429-1200', 'CODE-TEST-2', 'Active', 'SINGLE',
                 '2026-04-29 14:00:00+00', '2026-04-29 11:45:00+00', 36.00, 'DKK')$sql$,
    '23514', 'tickets_validity_window');
select pg_temp.rejects('duplicate ticket code',
    $sql$insert into tickets (id, user_id, trip_id, ticket_code, status, product_code, valid_from_utc, valid_to_utc, price, currency)
         values ('T-TEST-2', 'USER-3', 'TRIP-M2-20260429-1200', 'CODE-M2-0001', 'Active', 'SINGLE',
                 '2026-04-29 11:45:00+00', '2026-04-29 14:00:00+00', 36.00, 'DKK')$sql$,
    '23505', 'tickets_ticket_code_unique');
select pg_temp.rejects('unknown ticket status',
    $sql$update tickets set status = 'Unknown' where id = 'TICKET-1'$sql$,
    '23514', 'tickets_status_known');
select pg_temp.rejects('negative ticket price',
    $sql$update tickets set price = -1 where id = 'TICKET-1'$sql$,
    '23514', 'tickets_price_non_negative');
select pg_temp.rejects('two-letter ticket currency',
    $sql$update tickets set currency = 'DK' where id = 'TICKET-1'$sql$,
    '23514', 'tickets_currency_iso_format');
select pg_temp.rejects('missing ticket code',
    $sql$update tickets set ticket_code = null where id = 'TICKET-1'$sql$,
    '23502', 'ticket_code');

\echo '== Payments'
select pg_temp.accepts('pending payment before the gateway returns a reference',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-PENDING', 'USER-3', 'T-TEST-1', null, 36.00, 'DKK', 'Pending')$sql$);
select pg_temp.accepts('captured payment with a new reference',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-CAPTURED', 'USER-3', 'T-TEST-1', 'gateway-capture-test-1', 36.00, 'DKK', 'Captured')$sql$);
select pg_temp.rejects('payment for an unknown ticket',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-3', 'NO-SUCH-TICKET', 'gateway-capture-test-x', 36.00, 'DKK', 'Captured')$sql$,
    '23503', 'payments_ticket_fk');
select pg_temp.rejects('payment by an unknown user',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-DOES-NOT-EXIST', 'T-TEST-1', 'gateway-capture-test-x', 36.00, 'DKK', 'Captured')$sql$,
    '23503', 'payments_user_fk');
select pg_temp.rejects('lower-case payment currency',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-3', 'T-TEST-1', 'gateway-capture-test-x', 36.00, 'dkk', 'Captured')$sql$,
    '23514', 'payments_currency_iso_format');
select pg_temp.rejects('negative payment amount',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-3', 'T-TEST-1', 'gateway-capture-test-x', -36.00, 'DKK', 'Captured')$sql$,
    '23514', 'payments_amount_non_negative');
select pg_temp.rejects('unknown payment status',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-3', 'T-TEST-1', 'gateway-capture-test-x', 36.00, 'DKK', 'Paid')$sql$,
    '23514', 'payments_status_known');
select pg_temp.rejects('captured payment without a gateway reference',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-3', 'T-TEST-1', null, 36.00, 'DKK', 'Captured')$sql$,
    '23514', 'payments_captured_has_reference');
select pg_temp.rejects('same capture recorded twice',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-1', 'TICKET-1', 'gateway-capture-0001', 36.00, 'DKK', 'Captured')$sql$,
    '23505', 'payments_captured_reference_unique');
select pg_temp.accepts('refund updates the captured row',
    $sql$update payments set status = 'Refunded' where id = 'PAYMENT-2'$sql$);
select pg_temp.rejects('capture delivered again after it was refunded',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-X', 'USER-2', 'TICKET-2', 'gateway-capture-0002', 36.00, 'DKK', 'Captured')$sql$,
    '23505', 'payments_captured_reference_unique');
select pg_temp.accepts('failed attempt that reuses a captured reference (outside the index by design)',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-FAILED', 'USER-1', 'TICKET-1', 'gateway-capture-0001', 36.00, 'DKK', 'Failed')$sql$);

\echo '== Deletes that would erase history'
select pg_temp.rejects('delete a ticket that has a payment',
    $sql$delete from tickets where id = 'TICKET-1'$sql$,
    '23503', 'payments_ticket_fk');
select pg_temp.rejects('delete a product that tickets were sold for',
    $sql$delete from products where code = 'SINGLE'$sql$,
    '23503', 'tickets_product_fk');

\echo '== Validations'
select pg_temp.accepts('validation whose code belongs to the ticket',
    $sql$insert into validations (id, ticket_id, ticket_code, vehicle_id, stop_id, device_id, result, validated_utc)
         values ('VAL-TEST-1', 'TICKET-1', 'CODE-M2-0001', 'METRO-M2-01', 'STOP-NORREPORT', 'DEVICE-02', 'Accepted', '2026-04-29 08:05:00+00')$sql$);
select pg_temp.rejects('ticket id combined with the code of another ticket',
    $sql$insert into validations (id, ticket_id, ticket_code, vehicle_id, stop_id, device_id, result, validated_utc)
         values ('VAL-TEST-2', 'TICKET-1', 'CODE-5C-0001', 'METRO-M2-01', 'STOP-NORREPORT', 'DEVICE-02', 'Accepted', '2026-04-29 08:05:00+00')$sql$,
    '23503', 'validations_ticket_fk');
select pg_temp.rejects('validation for an unknown ticket',
    $sql$insert into validations (id, ticket_id, ticket_code, vehicle_id, stop_id, device_id, result, validated_utc)
         values ('VAL-TEST-2', 'NO-SUCH-TICKET', 'NO-SUCH-CODE', 'METRO-M2-01', 'STOP-NORREPORT', 'DEVICE-02', 'Rejected', '2026-04-29 08:05:00+00')$sql$,
    '23503', 'validations_ticket_fk');
select pg_temp.rejects('validation at an unknown stop',
    $sql$insert into validations (id, ticket_id, ticket_code, vehicle_id, stop_id, device_id, result, validated_utc)
         values ('VAL-TEST-2', 'TICKET-1', 'CODE-M2-0001', 'METRO-M2-01', 'STOP-NOWHERE', 'DEVICE-02', 'Accepted', '2026-04-29 08:05:00+00')$sql$,
    '23503', 'validations_stop_fk');
select pg_temp.rejects('unknown validation result',
    $sql$insert into validations (id, ticket_id, ticket_code, vehicle_id, stop_id, device_id, result, validated_utc)
         values ('VAL-TEST-2', 'TICKET-1', 'CODE-M2-0001', 'METRO-M2-01', 'STOP-NORREPORT', 'DEVICE-02', 'Maybe', '2026-04-29 08:05:00+00')$sql$,
    '23514', 'validations_result_known');
select pg_temp.rejects('validation without the scanned code',
    $sql$insert into validations (id, ticket_id, ticket_code, vehicle_id, stop_id, device_id, result, validated_utc)
         values ('VAL-TEST-2', 'TICKET-1', null, 'METRO-M2-01', 'STOP-NORREPORT', 'DEVICE-02', 'Accepted', '2026-04-29 08:05:00+00')$sql$,
    '23502', 'ticket_code');

\echo '== Boundaries: rules a constraint does not cover'
select pg_temp.gap('seat counter no longer matches the tickets sold',
    $sql$update trips set reserved_seats = 0 where id = 'TRIP-M2-20260429-0800'$sql$);
select pg_temp.gap('price of a sold ticket rewritten afterwards',
    $sql$update tickets set price = 0 where id = 'TICKET-3'$sql$);
select pg_temp.gap('captured amount differs from the ticket price',
    $sql$insert into payments (id, user_id, ticket_id, external_payment_reference, amount, currency, status)
         values ('PAY-TEST-OVER', 'USER-3', 'T-TEST-1', 'gateway-capture-test-2', 50.00, 'DKK', 'Captured')$sql$);
select pg_temp.gap('accepted validation outside the ticket validity window',
    $sql$insert into validations (id, ticket_id, ticket_code, vehicle_id, stop_id, device_id, result, validated_utc)
         values ('VAL-TEST-LATE', 'TICKET-3', 'CODE-DAY-0001', 'METRO-M2-01', 'STOP-NORREPORT', 'DEVICE-02', 'Accepted', '2026-05-02 10:00:00+00')$sql$);
select pg_temp.accepts('disable a user',
    $sql$update users set is_disabled = true where id = 'USER-3'$sql$);
select pg_temp.gap('disabled user buys a ticket',
    $sql$insert into tickets (id, user_id, trip_id, ticket_code, status, product_code, valid_from_utc, valid_to_utc, price, currency)
         values ('T-TEST-3', 'USER-3', 'TRIP-5C-20260429-1700', 'CODE-TEST-3', 'Active', 'SINGLE',
                 '2026-04-29 16:45:00+00', '2026-04-29 19:00:00+00', 36.00, 'DKK')$sql$);

rollback;

\echo 'All checks passed. Every change was rolled back.'
