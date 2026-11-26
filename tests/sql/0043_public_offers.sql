-- Expected result: error PASS_ROLLBACK. Needs seeded MC-KER-001-50ML and no live offers.
do $$
declare pk uuid := (select product_id from variants where sku = 'MC-KER-001-50ML'); price int := (select price_paise from variants where sku = 'MC-KER-001-50ML'); r record; n int;
begin
  select count(*) into n from public_offers(); if n <> 0 then raise exception 'FAIL expected none, got %', n; end if;
  insert into offers (title, kind, type, value, scope, product_ids) values ('Sale 20', 'sale', 'percent', 20, 'products', array[pk]);
  insert into offers (title, kind, type, buy_qty, get_qty, scope, product_ids) values ('B1G1', 'bogo', 'buy_get', 1, 1, 'products', array[pk]);
  insert into offers (title, kind, type, value, scope, audience, product_ids) values ('Members', 'member', 'percent', 90, 'products', 'society_members', array[pk]);
  select * into r from public_offers() where sku = 'MC-KER-001-50ML';
  if r.label <> 'Buy 1, get 1 free' then raise exception 'FAIL best got %', r.label; end if;
  update offers set is_active = false where title = 'B1G1';
  select * into r from public_offers() where sku = 'MC-KER-001-50ML';
  if r.label <> '20% off' or r.sale_price_paise <> price - price * 20 / 100 then raise exception 'FAIL percent'; end if;
  update offers set type = 'flat', value = 20000 where title = 'Sale 20';
  select * into r from public_offers() where sku = 'MC-KER-001-50ML';
  if r.label <> '₹200 off' or r.sale_price_paise <> price - 20000 then raise exception 'FAIL flat'; end if;
  raise exception 'PASS_ROLLBACK';
end $$;
