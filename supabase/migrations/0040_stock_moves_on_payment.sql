-- Migration 0040: stock changes only when payment is confirmed, and comes back on refund or return.
-- 1. Opening checkout / the payment page no longer holds stock. Checkout still refuses an item that is out of stock.
--    If the last unit is paid for twice, the payment that is confirmed second is refunded automatically (existing refund_needed path).
-- 2. A confirmed order that is refunded before it ships, or that is returned, puts its units back on the shelf, once.
-- The existing functions are patched in place so nothing else about them changes; every patch must match or the migration fails.

alter table orders add column stock_restocked boolean not null default false;

create function _patch_function(p_sig text, p_old text, p_new text) returns void
language plpgsql as $$
declare d text; n text;
begin
  d := pg_get_functiondef(p_sig::regprocedure);
  n := replace(d, p_old, p_new);
  if n = d then raise exception 'patch_not_applied: % / %', p_sig, left(p_old, 60); end if;
  execute n;
end $$;

-- 1. No hold at checkout.
select _patch_function('begin_retail_checkout(uuid,jsonb,jsonb,text)',
  $o$if reserve_stock(ln.variant_id, ln.qty, oid) <> 'reserved' then raise exception 'out_of_stock'; end if;$o$,
  $n$if (select stock_on_hand from variants where id = ln.variant_id) < ln.qty then raise exception 'out_of_stock'; end if;$n$);
select _patch_function('begin_retail_checkout(uuid,jsonb,jsonb,text)',
  $o$update orders set stock_held = true where id = oid;$o$, $n$null;$n$);
select _patch_function('begin_launch_checkout(uuid,text,text,jsonb)',
  $o$if reserve_stock(rv.id, 1, oid) <> 'reserved' then raise exception 'out_of_stock'; end if;$o$,
  $n$if (select stock_on_hand from variants where id = rv.id) < 1 then raise exception 'out_of_stock'; end if;$n$);
select _patch_function('begin_launch_checkout(uuid,text,text,jsonb)',
  $o$update orders set stock_held = true where id = oid;$o$, $n$null;$n$);

-- 2. Units go back once, and only if they were actually taken off the shelf for this order.
create function _restock_order(p_order uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype; ln record;
begin
  select * into o from orders where id = p_order for update;
  if not found or o.stock_restocked then return; end if;
  if not exists (select 1 from inventory_movements where order_id = p_order and movement = 'commit') then return; end if;
  for ln in select * from _order_stock_lines(p_order) loop
    update variants set stock_on_hand = stock_on_hand + ln.qty where id = ln.variant_id;
    insert into inventory_movements (variant_id, movement, quantity, order_id, reason) values (ln.variant_id, 'return', ln.qty, p_order, p_reason);
  end loop;
  update orders set stock_restocked = true where id = p_order;
end $$;
revoke execute on function _restock_order(uuid, text) from public, anon, authenticated;
grant execute on function _restock_order(uuid, text) to service_role;

-- Fully refunded: restock unless the parcel already left (then it is restocked when it comes back as returned).
select _patch_function('process_refund_event(text,text,text,int,text,jsonb)',
  $o$update orders set payment_status = 'refunded' where id = o.id;$o$,
  $n$update orders set payment_status = 'refunded' where id = o.id;
      if o.fulfilment_status in ('unfulfilled', 'processing', 'packed', 'cancelled') then perform _restock_order(o.id, 'order refunded'); end if;$n$);

-- A returned parcel goes back on the shelf.
select _patch_function('admin_set_fulfilment(uuid,fulfilment_status,text,text,text,text,date)',
  $o$perform _hist(p_order, 'fulfilment', o.fulfilment_status::text, p_status::text, p_note);$o$,
  $n$perform _hist(p_order, 'fulfilment', o.fulfilment_status::text, p_status::text, p_note);
  if p_status = 'returned' then perform _restock_order(p_order, 'parcel returned'); end if;$n$);

drop function _patch_function(text, text, text);
