create or replace function admin_set_fulfilment(p_order uuid, p_status fulfilment_status, p_courier text default null, p_tracking text default null,
  p_note text default null, p_tracking_url text default null, p_estimated_delivery date default null) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype; ok boolean; v_email text;
begin
  perform _require('orders.manage');
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'not_found'; end if;
  if p_status = 'cancelled' then
    if o.payment_status = 'captured' then raise exception 'refund_required'; end if;
    perform _cancel_unpaid_order(p_order, coalesce(nullif(trim(p_note), ''), 'cancelled by staff'));
    perform _audit('order.cancel', 'order', p_order::text, p_note, to_jsonb(o.fulfilment_status), to_jsonb(p_status));
    return;
  end if;
  if o.payment_status <> 'captured' then raise exception 'not_paid'; end if;
  ok := (o.fulfilment_status = 'unfulfilled' and p_status = 'processing')
     or (o.fulfilment_status = 'processing' and p_status = 'packed')
     or (o.fulfilment_status = 'packed' and p_status = 'shipped')
     or (o.fulfilment_status = 'shipped' and p_status in ('in_transit', 'out_for_delivery', 'delivery_failed', 'delivered'))
     or (o.fulfilment_status = 'in_transit' and p_status in ('out_for_delivery', 'delivery_failed', 'delivered'))
     or (o.fulfilment_status = 'out_for_delivery' and p_status in ('delivered', 'delivery_failed'))
     or (o.fulfilment_status = 'delivery_failed' and p_status in ('out_for_delivery', 'in_transit', 'returned'))
     or (o.fulfilment_status = 'delivered' and p_status = 'return_requested')
     or (o.fulfilment_status = 'return_requested' and p_status = 'returned');
  if not ok then raise exception 'invalid_transition'; end if;
  if p_status = 'shipped' and (coalesce(trim(p_courier), '') = '' or coalesce(trim(p_tracking), '') = '') then
    raise exception 'tracking_required'; end if;
  if p_tracking_url is not null and p_tracking_url !~ '^https?://' then raise exception 'invalid_tracking_url'; end if;
  update orders set fulfilment_status = p_status,
         courier = coalesce(nullif(trim(p_courier), ''), courier),
         tracking_number = coalesce(nullif(trim(p_tracking), ''), tracking_number),
         tracking_url = coalesce(nullif(trim(p_tracking_url), ''), tracking_url),
         estimated_delivery = coalesce(p_estimated_delivery, estimated_delivery),
         shipped_at = case when p_status = 'shipped' then now() else shipped_at end
   where id = p_order;
  perform _hist(p_order, 'fulfilment', o.fulfilment_status::text, p_status::text, p_note);
  perform _audit('order.fulfilment', 'order', p_order::text, p_note, to_jsonb(o.fulfilment_status), to_jsonb(p_status));
  if p_status = 'shipped' then
    select email into v_email from customers where id = o.customer_id;
    perform _enqueue('order_shipped:' || p_order, 'email', v_email, 'order_shipped',
      jsonb_build_object('order_number', o.order_number, 'courier', p_courier, 'tracking_number', p_tracking));
  end if;
end $$;
revoke execute on function public.admin_set_fulfilment(uuid, fulfilment_status, text, text, text, text, date) from public, anon;
grant execute on function public.admin_set_fulfilment(uuid, fulfilment_status, text, text, text, text, date) to authenticated, service_role;
