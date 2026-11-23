-- Expected result: error PASS_ROLLBACK. Needs the two seeded published products (MC-KER-001-50ML, MC-JAP-001-50ML) and one customer.
do $$
declare r record; cust uuid := (select id from customers limit 1); addr jsonb := '{"name":"T","phone":"9876543210","line1":"x","city":"Kochi","state_code":"32","pincode":"682001"}';
        kerala uuid := (select product_id from variants where sku = 'MC-KER-001-50ML'); d int;
begin
  perform set_config('request.jwt.claims', '{"sub":"e657ce70-0442-451a-b394-68dc59cb6dcb","role":"authenticated"}', true);
  update variants set stock_on_hand = 100;
  insert into coupons (code, discount_type, value, max_discount_paise) values ('T-CAP', 'percent', 50, 10000);
  select * into r from begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":1}]', addr, 'T-CAP');
  select discount_paise into d from orders where id = r.r_order_id;
  if d <> 10000 then raise exception 'FAIL cap got %', d; end if;
  insert into coupons (code, discount_type, value, product_ids) values ('T-PROD', 'percent', 10, array[kerala]);
  select * into r from begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":1},{"sku":"MC-JAP-001-50ML","qty":1}]', addr, 'T-PROD');
  select discount_paise into d from orders where id = r.r_order_id;
  if d <> 14990 then raise exception 'FAIL product got %', d; end if;
  begin perform begin_retail_checkout(cust, '[{"sku":"MC-JAP-001-50ML","qty":1}]', addr, 'T-PROD'); raise exception 'FAIL ineligible'; exception when others then if sqlerrm <> 'invalid_coupon' then raise; end if; end;
  insert into coupons (code, discount_type, value, max_per_customer) values ('T-ONE', 'flat', 5000, 1);
  perform begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":1}]', addr, 'T-ONE');
  begin perform begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":1}]', addr, 'T-ONE'); raise exception 'FAIL per-customer'; exception when others then if sqlerrm <> 'invalid_coupon' then raise; end if; end;
  insert into coupons (code, discount_type, value, tiers) values ('T-TIER', 'flat', 5000, array[1]);
  begin perform begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":1}]', addr, 'T-TIER'); raise exception 'FAIL tier'; exception when others then if sqlerrm <> 'invalid_coupon' then raise; end if; end;
  perform admin_set_coupon_rules('T-ONE', 2, null, null, null, 'test');
  begin perform admin_set_coupon_rules('T-ONE', 2, null, null, array[99], 'test'); raise exception 'FAIL bad tier'; exception when others then if sqlerrm <> 'invalid_input' then raise; end if; end;
  raise exception 'PASS_ROLLBACK';
end $$;
