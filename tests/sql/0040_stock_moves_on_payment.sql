-- Expected result: error PASS_ROLLBACK. Needs the seeded product MC-KER-001-50ML and one customer.
do $$
declare r record; cust uuid := (select id from customers limit 1); addr jsonb := '{"name":"T","phone":"9876543210","line1":"x","city":"Kochi","state_code":"32","pincode":"682001"}';
        vid uuid := (select id from variants where sku = 'MC-KER-001-50ML'); oh int; rs int; o orders%rowtype; pay payments%rowtype; res record;
begin
  update variants set stock_on_hand = 10, stock_reserved = 0 where id = vid;
  select * into r from begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":2}]', addr, null);
  select stock_on_hand, stock_reserved into oh, rs from variants where id = vid;
  if oh <> 10 or rs <> 0 then raise exception 'FAIL checkout changed stock % %', oh, rs; end if;
  perform attach_razorpay_order(r.r_order_id, 'order_T40');
  select * into o from orders where id = r.r_order_id;
  select * into res from process_payment_captured('evt_t40a', 'order_T40', 'pay_T40', o.total_paise, '{}');
  select stock_on_hand into oh from variants where id = vid;
  if res.r_result <> 'ok' or oh <> 8 then raise exception 'FAIL capture result % stock %', res.r_result, oh; end if;
  perform process_refund_event('evt_t40b', 'rfnd_T40', 'pay_T40', o.total_paise, 'processed', '{}');
  select stock_on_hand into oh from variants where id = vid;
  if oh <> 10 then raise exception 'FAIL refund restock %', oh; end if;
  perform process_refund_event('evt_t40c', 'rfnd_T40', 'pay_T40', o.total_paise, 'processed', '{}');
  select stock_on_hand into oh from variants where id = vid;
  if oh <> 10 then raise exception 'FAIL double restock %', oh; end if;
  -- out of stock is still refused at checkout
  update variants set stock_on_hand = 1 where id = vid;
  begin perform begin_retail_checkout(cust, '[{"sku":"MC-KER-001-50ML","qty":2}]', addr, null); raise exception 'FAIL oversell'; exception when others then if sqlerrm <> 'out_of_stock' then raise; end if; end;
  raise exception 'PASS_ROLLBACK';
end $$;
