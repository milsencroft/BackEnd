create table order_pack_checks (
  order_id uuid not null references orders(id) on delete cascade,
  item_key text not null,
  checked_by uuid,
  checked_at timestamptz not null default now(),
  primary key (order_id, item_key)
);
alter table order_pack_checks enable row level security;
revoke all on order_pack_checks from anon, authenticated;

create function _packing_items(p_order uuid) returns table(item_key text, label text)
language sql stable security definer set search_path = public as $$
  select 'item:' || i.id::text, i.name_snapshot || ' x' || i.quantity || ' (' || coalesce(i.sku_snapshot, 'no SKU') || ')' from order_items i where i.order_id = p_order
  union all select 'seal', 'Bottles checked for damage and sealed'
  union all select 'invoice', 'Invoice included'
  union all select 'society', 'Society card and collector package included'
    from orders o join launches l on l.id = o.launch_id where o.id = p_order and o.order_type = 'launch_preorder' and l.society_eligible $$;

create function admin_order_packing(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('orders.manage');
  return coalesce((select jsonb_agg(jsonb_build_object('key', p.item_key, 'label', p.label, 'checked', c.order_id is not null, 'checked_at', c.checked_at)
                   order by (p.item_key like 'item:%') desc, p.item_key)
                   from _packing_items(p_order) p left join order_pack_checks c on c.order_id = p_order and c.item_key = p.item_key), '[]'::jsonb);
end $$;

create function admin_pack_check(p_order uuid, p_key text, p_checked boolean) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype;
begin
  perform _require('orders.manage');
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'not_found'; end if;
  if o.payment_status <> 'captured' or o.fulfilment_status <> 'processing' then raise exception 'not_packing'; end if;
  if not exists (select 1 from _packing_items(p_order) where item_key = p_key) then raise exception 'invalid_item'; end if;
  if p_checked then
    insert into order_pack_checks (order_id, item_key, checked_by) values (p_order, p_key, current_customer_id()) on conflict do nothing;
  else
    delete from order_pack_checks where order_id = p_order and item_key = p_key;
  end if;
  perform _audit('order.pack_check', 'order', p_order::text, 'Packing checklist', null, jsonb_build_object('item', p_key, 'checked', p_checked));
end $$;

-- admin_set_fulfilment: unchanged from 0018 except an order cannot become 'packed' until every checklist item is ticked.
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
  if p_status = 'packed' and exists (select 1 from _packing_items(p_order) p
       where not exists (select 1 from order_pack_checks c where c.order_id = p_order and c.item_key = p.item_key)) then
    raise exception 'packing_incomplete';
  end if;
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

revoke execute on function public._packing_items(uuid) from public, anon, authenticated;
revoke execute on function public.admin_order_packing(uuid), public.admin_pack_check(uuid, text, boolean) from public, anon;
grant execute on function public.admin_order_packing(uuid), public.admin_pack_check(uuid, text, boolean) to authenticated;
revoke execute on function public.admin_set_fulfilment(uuid, fulfilment_status, text, text, text, text, date) from public, anon;
grant execute on function public.admin_set_fulfilment(uuid, fulfilment_status, text, text, text, text, date) to authenticated;
