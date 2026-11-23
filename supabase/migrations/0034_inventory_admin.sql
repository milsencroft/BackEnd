-- 0034: stock per SKU for staff (product managers and above). Storefront availability already derives from these numbers.
create or replace function admin_inventory_list() returns table(
  variant_id uuid, sku text, product_name text, size_ml int, is_active boolean,
  on_hand int, reserved int, available int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('inventory.view');
  return query select v.id, v.sku, p.name, v.size_ml, v.is_active, v.stock_on_hand, v.stock_reserved, greatest(v.stock_on_hand - v.stock_reserved, 0)
    from variants v join products p on p.id = v.product_id order by p.code, v.size_ml;
end $$;

-- Sets the exact quantity on hand. Reserved units (held by open checkouts) can never be taken away.
create or replace function admin_set_stock(p_variant uuid, p_quantity int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v variants%rowtype; d int;
begin
  perform _require('inventory.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_quantity is null or p_quantity < 0 or p_quantity > 100000 then raise exception 'invalid_quantity'; end if;
  select * into v from variants where id = p_variant for update;
  if not found then raise exception 'not_found'; end if;
  if p_quantity < v.stock_reserved then raise exception 'below_reserved'; end if;
  d := p_quantity - v.stock_on_hand;
  if d = 0 then return; end if;
  update variants set stock_on_hand = p_quantity where id = p_variant;
  insert into inventory_movements (variant_id, movement, quantity, reason, actor_customer_id)
  values (p_variant, case when d > 0 then 'restock' else 'adjust' end, abs(d), p_reason, current_customer_id());
  perform _audit('stock.set', 'variant', p_variant::text, p_reason, to_jsonb(v.stock_on_hand), to_jsonb(p_quantity));
end $$;

revoke all on function admin_inventory_list(), admin_set_stock(uuid, int, text) from public, anon;
grant execute on function admin_inventory_list(), admin_set_stock(uuid, int, text) to authenticated;
revoke all on function admin_adjust_stock(uuid, int, text) from public, anon;
grant execute on function admin_adjust_stock(uuid, int, text) to authenticated;
