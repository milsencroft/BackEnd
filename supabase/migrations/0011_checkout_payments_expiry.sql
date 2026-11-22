-- Migration 0011: transactional checkout, payment webhooks, refunds and expiry. Server-side only (service_role).
alter table orders add column stock_held boolean not null default false;
insert into store_settings (key, value) values ('shipping', '{"flat_paise": 0, "free_above_paise": null}') on conflict do nothing;

create function _audit(p_action text, p_type text, p_id text, p_reason text, p_before jsonb, p_after jsonb) returns void
language sql security definer set search_path = public as $$
  insert into audit_log (actor_customer_id, action, entity_type, entity_id, reason, before_data, after_data)
  values (current_customer_id(), p_action, p_type, p_id, p_reason, p_before, p_after)
$$;

create function _hist(p_order uuid, p_kind text, p_from text, p_to text, p_note text default null) returns void
language sql security definer set search_path = public as $$
  insert into order_status_history (order_id, kind, from_status, to_status, actor_customer_id, note)
  values (p_order, p_kind, p_from, p_to, current_customer_id(), p_note)
$$;

create function _enqueue(p_event text, p_channel text, p_recipient text, p_template text, p_payload jsonb) returns void
language sql security definer set search_path = public as $$
  insert into notification_outbox (event_id, channel, recipient, template, payload)
  values (p_event, p_channel, p_recipient, p_template, coalesce(p_payload, '{}'))
  on conflict (event_id) do nothing
$$;

create function _validate_address(a jsonb) returns void language plpgsql immutable set search_path = public as $$
begin
  if a is null or jsonb_typeof(a) <> 'object' then raise exception 'invalid_address'; end if;
  if coalesce(trim(a->>'name'), '') = '' or coalesce(trim(a->>'line1'), '') = '' or coalesce(trim(a->>'city'), '') = '' then
    raise exception 'invalid_address'; end if;
  if coalesce(a->>'phone', '') !~ '^[6-9][0-9]{9}$' then raise exception 'invalid_address'; end if;
  if coalesce(a->>'pincode', '') !~ '^[1-9][0-9]{5}$' then raise exception 'invalid_address'; end if;
  if coalesce(a->>'state_code', '') !~ '^[0-9]{2}$' then raise exception 'invalid_address'; end if;
end $$;

create function _variant_in_unreleased_launch(p_variant uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from launch_variants lv join launches l on l.id = lv.launch_id
                  where lv.variant_id = p_variant
                    and l.status not in ('published_in_shop', 'completed', 'cancelled', 'archived'))
$$;

create function _order_stock_lines(p_order uuid) returns table (variant_id uuid, qty int)
language sql stable security definer set search_path = public as $$
  select t.variant_id, t.qty from (
    select oi.variant_id, oi.quantity as qty from order_items oi where oi.order_id = p_order and oi.variant_id is not null
    union all
    select bi.variant_id, bi.quantity * oi.quantity from order_items oi
      join bundle_items bi on bi.bundle_id = oi.bundle_id where oi.order_id = p_order and oi.bundle_id is not null
  ) t order by t.variant_id
$$;

create function _cancel_unpaid_order(p_order uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype; ln record;
begin
  select * into o from orders where id = p_order for update;
  if not found or o.payment_status not in ('created', 'pending', 'failed') or o.fulfilment_status = 'cancelled' then return; end if;
  if o.stock_held then
    for ln in select * from _order_stock_lines(p_order) loop
      perform release_stock(ln.variant_id, ln.qty, p_order, p_reason);
    end loop;
  end if;
  update orders set fulfilment_status = 'cancelled', payment_status = 'failed', stock_held = false,
         notes = coalesce(notes || E'\n', '') || p_reason where id = p_order;
  update payments set status = 'failed', failure_reason = coalesce(failure_reason, p_reason)
   where order_id = p_order and status in ('created', 'pending');
  perform _hist(p_order, 'fulfilment', o.fulfilment_status::text, 'cancelled', p_reason);
  perform _hist(p_order, 'payment', o.payment_status::text, 'failed', p_reason);
end $$;

-- Launch pre-order: needs an active reservation. One bottle per slot. Prices come from the database only.
create function begin_launch_checkout(p_customer uuid, p_launch_code text, p_sku text, p_address jsonb)
returns table (r_result text, r_order_id uuid, r_order_number text, r_total_paise int)
language plpgsql security definer set search_path = public as $$
declare l launches%rowtype; res slot_reservations%rowtype; rv variants%rowtype; rlv launch_variants%rowtype;
        rp products%rowtype; g record; old record; price int; total int; oid uuid; onum text;
begin
  perform _validate_address(p_address);
  select * into l from launches where code = p_launch_code;
  if not found then return query select 'not_found'::text, null::uuid, null::text, null::int; return; end if;
  if l.status <> 'preorder_active' then return query select 'closed'::text, null::uuid, null::text, null::int; return; end if;
  select * into res from slot_reservations
   where launch_id = l.id and customer_id = p_customer and status = 'active' and expires_at > now()
   order by created_at desc limit 1;
  if not found then return query select 'no_reservation'::text, null::uuid, null::text, null::int; return; end if;
  select * into rv from variants where sku = p_sku and is_active;
  if not found then return query select 'invalid_item'::text, null::uuid, null::text, null::int; return; end if;
  select * into rlv from launch_variants where launch_id = l.id and variant_id = rv.id and is_available;
  if not found then return query select 'invalid_item'::text, null::uuid, null::text, null::int; return; end if;
  select * into rp from products where id = rv.product_id;
  if rp.status not in ('approved', 'published') then
    return query select 'invalid_item'::text, null::uuid, null::text, null::int; return; end if;

  for old in select id from orders where reservation_id = res.id and payment_status in ('created', 'pending', 'failed')
                                      and fulfilment_status <> 'cancelled' loop
    perform _cancel_unpaid_order(old.id, 'superseded by new checkout');
  end loop;

  price := coalesce(rlv.launch_price_paise, rv.price_paise);
  select * into g from calc_gst(price, p_address->>'state_code', rp.gst_rate_bps);
  total := price + g.r_amount_to_add_paise;

  insert into orders (customer_id, order_type, launch_id, reservation_id, subtotal_paise, tax_paise, total_paise,
                      shipping_address, gst_mode, gst_rate_bps, ship_state_code, cgst_paise, sgst_paise, igst_paise)
  values (p_customer, 'launch_preorder', l.id, res.id, price, g.r_tax_paise, total, p_address,
          nullif(g.r_mode, 'off'), nullif(g.r_rate_bps, 0), p_address->>'state_code',
          g.r_cgst_paise, g.r_sgst_paise, g.r_igst_paise)
  returning id, order_number into oid, onum;
  insert into order_items (order_id, variant_id, name_snapshot, sku_snapshot, quantity, unit_price_paise, line_total_paise)
  values (oid, rv.id, rp.name || ' ' || rv.size_ml || ' ml', rv.sku, 1, price, price);

  if reserve_stock(rv.id, 1, oid) <> 'reserved' then raise exception 'out_of_stock'; end if;
  update orders set stock_held = true where id = oid;
  perform _hist(oid, 'payment', null, 'created');
  perform _hist(oid, 'fulfilment', null, 'unfulfilled');
  return query select 'ok'::text, oid, onum, total;
end $$;

-- Regular retail: variants and bundles. Launch-only products are refused until the launch reaches the shop.
create function begin_retail_checkout(p_customer uuid, p_items jsonb, p_address jsonb, p_coupon text default null)
returns table (r_result text, r_order_id uuid, r_order_number text, r_total_paise int)
language plpgsql security definer set search_path = public as $$
declare it jsonb; rv variants%rowtype; rp products%rowtype; rb bundles%rowtype; cp coupons%rowtype; g record; ln record; x record;
        lines jsonb := '[]'; rates int[] := '{}'; sub int := 0; disc int := 0; ship int := 0; total int; q int;
        oid uuid; onum text; s jsonb; rate int; n_rates int; min_rate int;
begin
  perform _validate_address(p_address);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 10 then
    raise exception 'invalid_items'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    begin q := (it->>'qty')::int; exception when others then raise exception 'invalid_items'; end;
    if q is null or q < 1 or q > 5 then raise exception 'invalid_items'; end if;
    if it ? 'sku' then
      select * into rv from variants where sku = it->>'sku' and is_active;
      if not found then raise exception 'invalid_item'; end if;
      select * into rp from products where id = rv.product_id;
      if rp.status <> 'published' then raise exception 'invalid_item'; end if;
      if _variant_in_unreleased_launch(rv.id) then raise exception 'launch_only'; end if;
      lines := lines || jsonb_build_object('variant_id', rv.id, 'name', rp.name || ' ' || rv.size_ml || ' ml',
                                           'sku', rv.sku, 'qty', q, 'unit', rv.price_paise);
      sub := sub + rv.price_paise * q;
      rates := rates || coalesce(rp.gst_rate_bps, -1);
    elsif it ? 'bundle' then
      select * into rb from bundles where code = it->>'bundle' and status = 'published';
      if not found then raise exception 'invalid_item'; end if;
      for x in select bi.variant_id from bundle_items bi where bi.bundle_id = rb.id loop
        select * into rv from variants where id = x.variant_id;
        select * into rp from products where id = rv.product_id;
        if not rv.is_active or rp.status <> 'published' then raise exception 'invalid_item'; end if;
        if _variant_in_unreleased_launch(rv.id) then raise exception 'launch_only'; end if;
        rates := rates || coalesce(rp.gst_rate_bps, -1);
      end loop;
      lines := lines || jsonb_build_object('bundle_id', rb.id, 'name', rb.name, 'sku', rb.code, 'qty', q, 'unit', rb.price_paise);
      sub := sub + rb.price_paise * q;
    else raise exception 'invalid_item';
    end if;
  end loop;

  if coalesce(trim(p_coupon), '') <> '' then
    select * into cp from coupons
     where code = upper(trim(p_coupon)) and is_active and (starts_at is null or starts_at <= now())
       and (ends_at is null or ends_at >= now()) and (max_uses is null or uses_count < max_uses) and min_order_paise <= sub;
    if not found then raise exception 'invalid_coupon'; end if;
    disc := case when cp.discount_type = 'percent' then (sub::bigint * cp.value / 100)::int else least(cp.value, sub) end;
  end if;

  select value into s from store_settings where key = 'shipping';
  ship := coalesce((s->>'flat_paise')::int, 0);
  if s->>'free_above_paise' is not null and (sub - disc) >= (s->>'free_above_paise')::int then ship := 0; end if;

  select count(distinct u), min(u) into n_rates, min_rate from unnest(rates) u;
  rate := case when n_rates = 1 and min_rate >= 0 then min_rate else null end;
  select * into g from calc_gst(sub - disc + ship, p_address->>'state_code', rate);
  total := sub - disc + ship + g.r_amount_to_add_paise;

  insert into orders (customer_id, order_type, subtotal_paise, discount_paise, shipping_paise, tax_paise, total_paise,
                      shipping_address, coupon_code, gst_mode, gst_rate_bps, ship_state_code, cgst_paise, sgst_paise, igst_paise)
  values (p_customer, 'regular_retail', sub, disc, ship, g.r_tax_paise, total, p_address, cp.code,
          nullif(g.r_mode, 'off'), nullif(g.r_rate_bps, 0), p_address->>'state_code',
          g.r_cgst_paise, g.r_sgst_paise, g.r_igst_paise)
  returning id, order_number into oid, onum;

  insert into order_items (order_id, variant_id, bundle_id, name_snapshot, sku_snapshot, quantity, unit_price_paise, line_total_paise)
  select oid, l.variant_id, l.bundle_id, l.name, l.sku, l.qty, l.unit, l.qty * l.unit
    from jsonb_to_recordset(lines) as l(variant_id uuid, bundle_id uuid, name text, sku text, qty int, unit int);

  for ln in select * from _order_stock_lines(oid) loop
    if reserve_stock(ln.variant_id, ln.qty, oid) <> 'reserved' then raise exception 'out_of_stock'; end if;
  end loop;
  update orders set stock_held = true where id = oid;
  perform _hist(oid, 'payment', null, 'created');
  perform _hist(oid, 'fulfilment', null, 'unfulfilled');
  return query select 'ok'::text, oid, onum, total;
end $$;

create function attach_razorpay_order(p_order uuid, p_rzp_order text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into payments (order_id, razorpay_order_id, amount_paise, status)
  select id, p_rzp_order, total_paise, 'created' from orders where id = p_order;
  update orders set payment_status = 'pending' where id = p_order and payment_status = 'created';
  perform _hist(p_order, 'payment', 'created', 'pending');
end $$;

-- Verified payment.captured. One transaction: duplicate-safe, amount-checked, refund_needed if slot or stock is gone.
create function process_payment_captured(p_event_id text, p_rzp_order text, p_rzp_payment text, p_amount int, p_payload jsonb default '{}')
returns table (r_result text, r_order_id uuid, r_payment_id uuid)
language plpgsql security definer set search_path = public as $$
declare n int; pay payments%rowtype; o orders%rowtype; ln record; c text; need_refund boolean := false; v_email text; v_part uuid;
begin
  insert into razorpay_events (event_id, event_type, payload) values (p_event_id, 'payment.captured', coalesce(p_payload, '{}'))
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return query select 'duplicate'::text, null::uuid, null::uuid; return; end if;

  select * into pay from payments where razorpay_order_id = p_rzp_order for update;
  if not found then
    update razorpay_events set processed_at = now() where event_id = p_event_id;
    return query select 'unknown_order'::text, null::uuid, null::uuid; return;
  end if;
  select * into o from orders where id = pay.order_id for update;
  if pay.status in ('captured', 'refund_pending', 'refunded') then
    update razorpay_events set processed_at = now() where event_id = p_event_id;
    return query select 'duplicate'::text, o.id, pay.id; return;
  end if;
  if p_amount <> pay.amount_paise or p_amount <> o.total_paise then
    update razorpay_events set processed_at = now() where event_id = p_event_id;
    update payments set razorpay_payment_id = coalesce(razorpay_payment_id, p_rzp_payment), failure_reason = 'amount_mismatch' where id = pay.id;
    perform _enqueue('staff_alert:amount_mismatch:' || pay.id, 'staff_alert', null, 'amount_mismatch',
      jsonb_build_object('order_number', o.order_number, 'expected_paise', o.total_paise, 'received_paise', p_amount, 'razorpay_payment_id', p_rzp_payment));
    return query select 'amount_mismatch'::text, o.id, pay.id; return;
  end if;

  begin
    if not o.stock_held then
      for ln in select * from _order_stock_lines(o.id) loop
        if reserve_stock(ln.variant_id, ln.qty, o.id) <> 'reserved' then raise exception 'refund_needed'; end if;
      end loop;
    end if;
    if o.order_type = 'launch_preorder' then
      c := confirm_launch_slot(o.launch_id, o.customer_id, o.id);
      if c not in ('allocated', 'existing') then raise exception 'refund_needed'; end if;
      select order_id into v_part from launch_participations where launch_id = o.launch_id and customer_id = o.customer_id;
      if v_part is distinct from o.id then raise exception 'refund_needed'; end if;
    end if;
    for ln in select * from _order_stock_lines(o.id) loop
      if commit_stock(ln.variant_id, ln.qty, o.id) <> 'committed' then raise exception 'refund_needed'; end if;
    end loop;
  exception when raise_exception then
    if sqlerrm <> 'refund_needed' then raise; end if;
    need_refund := true;
  end;

  update payments set razorpay_payment_id = p_rzp_payment, status = 'captured' where id = pay.id;
  select email into v_email from customers where id = o.customer_id;

  if need_refund then
    update orders set payment_status = 'refund_pending', fulfilment_status = 'cancelled', stock_held = false where id = o.id;
    perform _hist(o.id, 'payment', o.payment_status::text, 'captured', 'payment received');
    perform _hist(o.id, 'payment', 'captured', 'refund_pending', 'slot or stock unavailable after capture');
    perform _enqueue('refund_notice:' || o.id, 'email', v_email, 'refund_notice', jsonb_build_object('order_number', o.order_number));
    perform _enqueue('staff_alert:refund_fallback:' || o.id, 'staff_alert', null, 'refund_fallback', jsonb_build_object('order_number', o.order_number));
    update razorpay_events set processed_at = now() where event_id = p_event_id;
    return query select 'refund_needed'::text, o.id, pay.id; return;
  end if;

  update orders set payment_status = 'captured', stock_held = false,
         fulfilment_status = case when fulfilment_status = 'cancelled' then 'unfulfilled'::fulfilment_status else fulfilment_status end
   where id = o.id;
  perform _hist(o.id, 'payment', o.payment_status::text, 'captured');
  if o.fulfilment_status = 'cancelled' then perform _hist(o.id, 'fulfilment', 'cancelled', 'unfulfilled', 'late payment accepted'); end if;
  if o.coupon_code is not null then update coupons set uses_count = uses_count + 1 where code = o.coupon_code; end if;
  if o.order_type = 'launch_preorder' and (select society_eligible from launches where id = o.launch_id) then
    perform grant_membership(o.customer_id, o.launch_id, 1);
  end if;
  perform _enqueue('order_confirmed:' || o.id, 'email', v_email, 'order_confirmed',
    jsonb_build_object('order_number', o.order_number, 'total_paise', o.total_paise));
  perform _enqueue('staff_new_order:' || o.id, 'staff_alert', null, 'new_order',
    jsonb_build_object('order_number', o.order_number, 'total_paise', o.total_paise, 'order_type', o.order_type));
  update razorpay_events set processed_at = now() where event_id = p_event_id;
  return query select 'ok'::text, o.id, pay.id;
end $$;

-- A failed attempt does not cancel anything: the customer may retry on the same Razorpay order.
create function process_payment_failed(p_event_id text, p_rzp_order text, p_reason text, p_payload jsonb default '{}') returns text
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into razorpay_events (event_id, event_type, payload, processed_at) values (p_event_id, 'payment.failed', coalesce(p_payload, '{}'), now())
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'duplicate'; end if;
  update payments set failure_reason = p_reason where razorpay_order_id = p_rzp_order and status in ('created', 'pending');
  return 'ok';
end $$;

create function record_refund(p_payment uuid, p_rzp_refund text, p_amount int, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; ord uuid; prev text;
begin
  insert into refunds (payment_id, razorpay_refund_id, amount_paise, reason) values (p_payment, p_rzp_refund, p_amount, p_reason)
  on conflict (razorpay_refund_id) do nothing returning id into rid;
  update payments set status = 'refund_pending' where id = p_payment and status = 'captured' returning order_id into ord;
  if ord is not null then
    select payment_status::text into prev from orders where id = ord;
    if prev = 'captured' then
      update orders set payment_status = 'refund_pending' where id = ord;
      perform _hist(ord, 'payment', 'captured', 'refund_pending', p_reason);
    end if;
  end if;
  return rid;
end $$;

create function process_refund_event(p_event_id text, p_rzp_refund text, p_rzp_payment text, p_amount int, p_status text, p_payload jsonb default '{}') returns text
language plpgsql security definer set search_path = public as $$
declare n int; pay payments%rowtype; o orders%rowtype; v_total int; v_email text;
begin
  insert into razorpay_events (event_id, event_type, payload, processed_at) values (p_event_id, 'refund.' || p_status, coalesce(p_payload, '{}'), now())
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'duplicate'; end if;
  select * into pay from payments where razorpay_payment_id = p_rzp_payment for update;
  if not found then return 'unknown_payment'; end if;
  if exists (select 1 from refunds where razorpay_refund_id = p_rzp_refund) then
    update refunds set status = p_status where razorpay_refund_id = p_rzp_refund;
  else
    insert into refunds (payment_id, razorpay_refund_id, amount_paise, reason, status) values (pay.id, p_rzp_refund, p_amount, 'razorpay event', p_status);
  end if;
  if p_status = 'failed' then
    perform _enqueue('staff_alert:refund_failed:' || p_rzp_refund, 'staff_alert', null, 'refund_failed',
      jsonb_build_object('razorpay_payment_id', p_rzp_payment, 'razorpay_refund_id', p_rzp_refund));
    return 'ok';
  end if;
  select coalesce(sum(amount_paise), 0) into v_total from refunds where payment_id = pay.id and status = 'processed';
  if v_total >= pay.amount_paise then
    update payments set status = 'refunded' where id = pay.id;
    select * into o from orders where id = pay.order_id for update;
    if o.payment_status <> 'refunded' then
      update orders set payment_status = 'refunded' where id = o.id;
      perform _hist(o.id, 'payment', o.payment_status::text, 'refunded');
      select email into v_email from customers where id = o.customer_id;
      perform _enqueue('refund_done:' || o.id, 'email', v_email, 'refund_done', jsonb_build_object('order_number', o.order_number));
    end if;
  end if;
  return 'ok';
end $$;

create function expire_stale_orders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from orders where payment_status in ('created', 'pending') and fulfilment_status <> 'cancelled'
                                   and created_at < now() - interval '45 minutes' loop
    perform _cancel_unpaid_order(r.id, 'expired unpaid');
    n := n + 1;
  end loop;
  perform release_expired_reservations();
  return n;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    '_audit(text,text,text,text,jsonb,jsonb)', '_hist(uuid,text,text,text,text)', '_enqueue(text,text,text,text,jsonb)',
    '_validate_address(jsonb)', '_variant_in_unreleased_launch(uuid)', '_order_stock_lines(uuid)', '_cancel_unpaid_order(uuid,text)',
    'begin_launch_checkout(uuid,text,text,jsonb)', 'begin_retail_checkout(uuid,jsonb,jsonb,text)', 'attach_razorpay_order(uuid,text)',
    'process_payment_captured(text,text,text,int,jsonb)', 'process_payment_failed(text,text,text,jsonb)',
    'record_refund(uuid,text,int,text)', 'process_refund_event(text,text,text,int,text,jsonb)', 'expire_stale_orders()']
  loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
