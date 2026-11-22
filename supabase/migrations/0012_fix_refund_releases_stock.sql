-- Migration 0012: when payment is captured but the slot/stock is gone, release the stock the order was holding.
-- (Found by the checkout test: reserved stock stayed behind after the refund fallback.)
-- Same function as in 0011 with one added block in the refund branch.
create or replace function process_payment_captured(p_event_id text, p_rzp_order text, p_rzp_payment text, p_amount int, p_payload jsonb default '{}')
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
    if o.stock_held then
      for ln in select * from _order_stock_lines(o.id) loop
        perform release_stock(ln.variant_id, ln.qty, o.id, 'refund fallback');
      end loop;
    end if;
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
revoke execute on function public.process_payment_captured(text,text,text,int,jsonb) from public, anon, authenticated;
grant execute on function public.process_payment_captured(text,text,text,int,jsonb) to service_role;
