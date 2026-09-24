-- Lecture 2: invariants the database enforces for ticket purchase and validation.
-- Adds named constraints on top of init/010_ticketing_draft.sql, which stays unchanged.
-- Reasoning per rule: docs/evidence/lecture02/integrity-map.md

begin;
set local lock_timeout = '3s';

alter table trips
    alter column capacity set not null,
    alter column reserved_seats set not null,
    add constraint trips_capacity_non_negative
        check (capacity >= 0),
    add constraint trips_reserved_seats_within_capacity
        check (reserved_seats between 0 and capacity),
    add constraint trips_status_known
        check (status in ('Scheduled', 'Cancelled', 'Completed'));

alter table products
    alter column name set not null,
    alter column price set not null,
    alter column currency set not null,
    add constraint products_price_non_negative
        check (price >= 0),
    add constraint products_currency_iso_format
        check (currency ~ '^[A-Z]{3}$');

alter table users
    alter column email set not null,
    alter column is_disabled set not null;

create unique index users_email_lower_unique on users (lower(email));

alter table tickets
    alter column user_id set not null,
    alter column trip_id set not null,
    alter column ticket_code set not null,
    alter column status set not null,
    alter column product_code set not null,
    alter column valid_from_utc set not null,
    alter column valid_to_utc set not null,
    alter column price set not null,
    alter column currency set not null,
    add constraint tickets_user_fk
        foreign key (user_id) references users (id) on delete restrict,
    add constraint tickets_trip_fk
        foreign key (trip_id) references trips (id) on delete restrict,
    add constraint tickets_product_fk
        foreign key (product_code) references products (code) on delete restrict,
    add constraint tickets_ticket_code_unique
        unique (ticket_code),
    -- Adds nothing to uniqueness (id is already the primary key). It exists so
    -- validations can reference the (id, ticket_code) pair as one key.
    add constraint tickets_id_ticket_code_unique
        unique (id, ticket_code),
    add constraint tickets_status_known
        check (status in ('Pending', 'Active', 'Validated', 'Cancelled', 'Expired')),
    add constraint tickets_price_non_negative
        check (price >= 0),
    add constraint tickets_currency_iso_format
        check (currency ~ '^[A-Z]{3}$'),
    add constraint tickets_validity_window
        check (valid_to_utc >= valid_from_utc);

alter table payments
    alter column user_id set not null,
    alter column ticket_id set not null,
    alter column amount set not null,
    alter column currency set not null,
    alter column status set not null,
    alter column created_utc set not null,
    add constraint payments_ticket_fk
        foreign key (ticket_id) references tickets (id) on delete restrict,
    add constraint payments_user_fk
        foreign key (user_id) references users (id) on delete restrict,
    add constraint payments_amount_non_negative
        check (amount >= 0),
    add constraint payments_currency_iso_format
        check (currency ~ '^[A-Z]{3}$'),
    add constraint payments_status_known
        check (status in ('Pending', 'Captured', 'Failed', 'Refunded')),
    add constraint payments_captured_has_reference
        check (status not in ('Captured', 'Refunded') or external_payment_reference is not null);

-- A gateway capture is recorded once. Refunded rows stay in the index, so a late
-- duplicate of a capture that was later refunded is still rejected.
create unique index payments_captured_reference_unique
    on payments (external_payment_reference)
    where status in ('Captured', 'Refunded');

alter table validations
    alter column ticket_id set not null,
    alter column ticket_code set not null,
    alter column result set not null,
    alter column validated_utc set not null,
    add constraint validations_ticket_fk
        foreign key (ticket_id, ticket_code) references tickets (id, ticket_code) on delete restrict,
    add constraint validations_stop_fk
        foreign key (stop_id) references stops (id) on delete restrict,
    add constraint validations_result_known
        check (result in ('Accepted', 'Rejected'));

commit;
