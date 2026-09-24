-- Lecture 4, expand: give products a stable id and let tickets reference it.
-- Nothing is removed. tickets.product_code and its foreign key keep working for
-- old writers and readers. Run once.

begin;
set local lock_timeout = '3s';

alter table products add column id uuid;

update products
set id = gen_random_uuid()
where id is null;

alter table products
    alter column id set default gen_random_uuid(),
    alter column id set not null,
    add constraint products_id_unique unique (id),
    -- Target for tickets_product_pair_fk below.
    add constraint products_id_code_unique unique (id, code);

alter table tickets
    add column product_id uuid;

alter table tickets
    add constraint tickets_product_id_fk
        foreign key (product_id) references products (id) on delete restrict
        not valid,
    -- While both references exist they must name the same product. A null
    -- product_id skips the check, so tickets from old writers still pass.
    add constraint tickets_product_pair_fk
        foreign key (product_id, product_code) references products (id, code) on delete restrict
        not valid;

commit;
