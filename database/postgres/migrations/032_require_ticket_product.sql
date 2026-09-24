-- Lecture 4, require: product_id becomes the required product reference.
-- Apply only after the old writers are stopped and experiments/lecture04/verify.sql
-- returns no rows. tickets.product_code stays, and stays NOT NULL, until its
-- removal has been rehearsed with experiments/lecture04/remove_legacy.sql.

begin;
set local lock_timeout = '3s';

alter table tickets validate constraint tickets_product_id_fk;
alter table tickets validate constraint tickets_product_pair_fk;
alter table tickets alter column product_id set not null;

commit;
