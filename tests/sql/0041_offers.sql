-- Expected result: error PASS_ROLLBACK. Needs seeded MC-KER-001-50ML / MC-JAP-001-50ML and one customer.
do $$
declare r record; cust uuid := (select id from customers limit 1); addr jsonb := '{"name":"T","phone":"9876543210","line1":"x","city":"Kochi","state_code":"32","pincode":"682001"}';
        pk uuid := (select product_id from variants where sku = 'MC-KER-001-50ML'); price int := (select price_paise from variants where sku = 'MC-KER-001-50ML');
        reg uuid := (select region_id from products where id = (select product_id from variants where sku = 'MC-KER-001-50ML'));
        d int; labels text[]; blk boolean; oid uuid;
begin
  update variants set stock_on_hand = 100;
  update offers set is_active = false;
  select r_discount into d from offer_discount(cust, jsonb_build_array(jsonb_build_object('product_id', pk, 'qty', 2, 'unit', price)));
  if d <> 0 then raise exception 'FAIL no offer got %', d; end if;
  -- buy 1 get 1: two bottles, one free
  insert into offers (title, kind, type, buy_qty, get_qty, scope, product_ids) values ('B1G1', 'bogo', 'buy_get', 1, 1, 'products', array[pk]);
  select r_discount, r_labels into d, labels from offer_discount(cust, jsonb_build_array(jsonb_build_object('product_id', pk, 'qty', 2, 'unit', price)));
  if d <> price or labels <> array['B1G1'] then raise exception 'FAIL bogo % %', d, labels; end if;
  select r_discount into d from offer_discount(cust, jsonb_build_array(jsonb_build_object('product_id', pk, 'qty', 1, 'unit', price)));
  if d <> 0 then raise exception 'FAIL bogo single %', d; end if;
  -- the best of two offers wins, once
  insert into offers (title, kind, type, value, scope, region_ids) values ('Region 10', 'sale', 'percent', 10, 'regions', array[reg]);
  select r_discount into d from offer_discount(cust, jsonb_build_array(jsonb_build_object('product_id', pk, 'qty', 2, 'unit', price)));
  if d <> price then raise exception 'FAIL best-of % ', d; end if;
  -- checkout charges the discounted amount and records the offer
  select * into r from begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":2}]', addr, null);
  if (select discount_paise from orders where id = r.r_order_id) <> price or (select offer_discount_paise from orders where id = r.r_order_id) <> price
     or (select offer_labels from orders where id = r.r_order_id) <> array['B1G1'] then raise exception 'FAIL order discount'; end if;
  -- a coupon is refused while a non-stackable offer applies, and allowed when stacking is on
  insert into coupons (code, discount_type, value) values ('T41', 'flat', 1000);
  begin perform begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":2}]', addr, 'T41'); raise exception 'FAIL coupon not blocked'; exception when others then if sqlerrm <> 'invalid_coupon' then raise; end if; end;
  update offers set stack_with_coupons = true;
  select * into r from begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":2}]', addr, 'T41');
  if (select discount_paise from orders where id = r.r_order_id) <> price + 1000 then raise exception 'FAIL stacked'; end if;
  -- expired or switched-off offers do nothing; new-customer audience needs a customer
  update offers set ends_at = now() - interval '1 day';
  select r_discount into d from offer_discount(cust, jsonb_build_array(jsonb_build_object('product_id', pk, 'qty', 2, 'unit', price)));
  if d <> 0 then raise exception 'FAIL expired %', d; end if;
  update offers set is_active = false;
  insert into offers (title, kind, type, value, scope, audience) values ('Welcome', 'new_customer', 'percent', 20, 'all', 'new_customers');
  select r_discount into d from offer_discount(null, jsonb_build_array(jsonb_build_object('product_id', pk, 'qty', 1, 'unit', price)));
  if d <> 0 then raise exception 'FAIL guest new-customer %', d; end if;
  -- invalid offers are refused
  begin insert into offers (title, type, value, scope) values ('Bad', 'percent', 150, 'all'); raise exception 'FAIL percent'; exception when check_violation then null; end;
  begin insert into offers (title, type, buy_qty, get_qty, scope) values ('Too big', 'buy_get', 3, 3, 'all'); raise exception 'FAIL qty'; exception when check_violation then null; end;
  raise exception 'PASS_ROLLBACK';
end $$;
