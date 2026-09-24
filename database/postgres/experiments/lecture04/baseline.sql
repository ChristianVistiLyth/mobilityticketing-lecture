\set ON_ERROR_STOP on
select current_database();
select id, product_code, price, currency from tickets order by id;
select t.id,t.product_code from tickets t left join products p on p.code=t.product_code
where t.product_code is null or p.code is null;
do $$ begin
 if (select count(*) from tickets)<3 or (select count(distinct product_code) from tickets)<2 then
  raise exception 'Expected at least three tickets covering two products';
 end if;
 if exists(select 1 from tickets t left join products p on p.code=t.product_code where p.code is null) then
  raise exception 'Unresolved product reference';
 end if;
end $$;
