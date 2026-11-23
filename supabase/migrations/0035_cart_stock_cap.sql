-- 0035: the cart never holds more than is available; the shop reports how many can be added (max_qty, capped at 5).

-- Units a customer could buy right now for a SKU or a bundle (on hand minus held). Bundles: the limiting item decides.
create or replace function _available_for(p_sku text, p_bundle text) returns int
language sql stable security definer set search_path = public as $$
  select case when p_sku is not null
    then coalesce((select greatest(v.stock_on_hand - v.stock_reserved, 0) from variants v where v.sku = p_sku), 0)
    else coalesce((select min(greatest(v.stock_on_hand - v.stock_reserved, 0) / greatest(bi.quantity, 1))
                     from bundles b join bundle_items bi on bi.bundle_id = b.id join variants v on v.id = bi.variant_id where b.code = p_bundle), 0)
  end
$$;
revoke all on function _available_for(text, text) from public, anon, authenticated;
grant execute on function _available_for(text, text) to service_role;

create or replace function cart_add(p_customer uuid, p_guest text, p_sku text, p_bundle text, p_qty int) returns text
language plpgsql security definer set search_path = public as $$
declare c uuid; key text; rv variants%rowtype; rp products%rowtype; rb bundles%rowtype; x record; n int; have int; avail int; want int;
begin
  if (p_sku is null) = (p_bundle is null) or p_qty is null or p_qty < 1 then return 'invalid_item'; end if;
  p_qty := least(p_qty, 5);
  if p_sku is not null then
    select * into rv from variants where sku = p_sku and is_active;
    if not found then return 'invalid_item'; end if;
    select * into rp from products where id = rv.product_id;
    if rp.status <> 'published' then return 'invalid_item'; end if;
    if _variant_in_unreleased_launch(rv.id) then return 'launch_only'; end if;
    key := 'sku:' || p_sku;
  else
    select * into rb from bundles where code = p_bundle and status = 'published';
    if not found then return 'invalid_item'; end if;
    for x in select bi.variant_id from bundle_items bi where bi.bundle_id = rb.id loop
      select * into rv from variants where id = x.variant_id; select * into rp from products where id = rv.product_id;
      if not rv.is_active or rp.status <> 'published' then return 'invalid_item'; end if;
      if _variant_in_unreleased_launch(rv.id) then return 'launch_only'; end if;
    end loop;
    key := 'bundle:' || p_bundle;
  end if;
  avail := _available_for(p_sku, p_bundle);
  if avail < 1 then return 'out_of_stock'; end if;
  c := _cart_id(p_customer, p_guest, true);
  if c is null then return 'invalid_cart'; end if;
  select count(*) into n from cart_lines where cart_id = c and item_key <> key;
  if n >= 10 then return 'cart_full'; end if;
  select coalesce((select qty from cart_lines where cart_id = c and item_key = key), 0) into have;
  want := least(5, avail, have + p_qty);
  insert into cart_lines (cart_id, item_key, sku, bundle_code, qty) values (c, key, p_sku, p_bundle, want)
  on conflict (cart_id, item_key) do update set qty = want;
  update carts set updated_at = now() where id = c;
  return case when have + p_qty > want then 'capped' else 'ok' end;
end $$;

create or replace function cart_set_qty(p_customer uuid, p_guest text, p_sku text, p_bundle text, p_qty int) returns text
language plpgsql security definer set search_path = public as $$
declare c uuid; key text; avail int; want int;
begin
  if (p_sku is null) = (p_bundle is null) or p_qty is null then return 'invalid_item'; end if;
  key := case when p_sku is not null then 'sku:' || p_sku else 'bundle:' || p_bundle end;
  c := _cart_id(p_customer, p_guest, false);
  if c is null then return 'not_found'; end if;
  avail := _available_for(p_sku, p_bundle);
  if avail < 1 then return 'out_of_stock'; end if;
  want := greatest(1, least(5, avail, p_qty));
  update cart_lines set qty = want where cart_id = c and item_key = key;
  if not found then return 'not_found'; end if;
  update carts set updated_at = now() where id = c;
  return case when p_qty > want then 'capped' else 'ok' end;
end $$;
revoke all on function cart_add(uuid, text, text, text, int), cart_set_qty(uuid, text, text, text, int) from public, anon, authenticated;
grant execute on function cart_add(uuid, text, text, text, int), cart_set_qty(uuid, text, text, text, int) to service_role;

-- The cart view says how many of each line can be bought, so the quantity picker never offers more.
create or replace function cart_view(p_customer uuid, p_guest text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c uuid; lines jsonb;
begin
  c := _cart_id(p_customer, p_guest, false);
  if c is null then return jsonb_build_object('lines', '[]'::jsonb, 'count', 0, 'subtotal_paise', 0); end if;
  select coalesce(jsonb_agg(l order by created), '[]') into lines from (
    select cl.created_at as created, jsonb_build_object(
      'sku', cl.sku, 'bundle', cl.bundle_code, 'qty', cl.qty,
      'name', coalesce(p.name || ', ' || v.size_ml || ' ml', b.name),
      'unit_paise', coalesce(v.price_paise, b.price_paise),
      'max_qty', least(5, _available_for(cl.sku, cl.bundle_code)),
      'ok', case when cl.sku is not null
                 then v.id is not null and v.is_active and p.status = 'published' and not _variant_in_unreleased_launch(v.id) and (v.stock_on_hand - v.stock_reserved) >= cl.qty
                 else b.id is not null and b.status = 'published'
                      and not exists (select 1 from bundle_items bi join variants bv on bv.id = bi.variant_id join products bp on bp.id = bv.product_id
                                       where bi.bundle_id = b.id and (not bv.is_active or bp.status <> 'published' or _variant_in_unreleased_launch(bv.id) or (bv.stock_on_hand - bv.stock_reserved) < bi.quantity * cl.qty)) end
    ) as l
    from cart_lines cl
    left join variants v on v.sku = cl.sku left join products p on p.id = v.product_id
    left join bundles b on b.code = cl.bundle_code
    where cl.cart_id = c) q;
  return jsonb_build_object('lines', lines, 'count', (select coalesce(sum(qty), 0) from cart_lines where cart_id = c),
    'subtotal_paise', (select coalesce(sum((x->>'unit_paise')::int * (x->>'qty')::int), 0) from jsonb_array_elements(lines) x where (x->>'ok')::boolean));
end $$;
revoke all on function cart_view(uuid, text) from public, anon, authenticated;
grant execute on function cart_view(uuid, text) to service_role;

-- Shop lists carry max_qty (how many can be added, up to 5).
drop function shop_catalogue();
create function shop_catalogue() returns table(product_code text, product_name text, family text, region_code text, region_name text, story text, notes jsonb, images jsonb,
  sku text, size_ml int, price_paise int, compare_at_paise int, in_stock boolean, max_qty int)
language sql stable security definer set search_path = public as $$
  select p.code, p.name, p.family, r.code, r.name, p.story, p.notes, p.images, v.sku, v.size_ml, v.price_paise, v.compare_at_paise,
         (v.stock_on_hand - v.stock_reserved) > 0, least(5, greatest(v.stock_on_hand - v.stock_reserved, 0))
    from products p
    join regions r on r.id = p.region_id and r.status = 'published'
    join variants v on v.product_id = p.id and v.is_active
   where p.status = 'published' and not _variant_in_unreleased_launch(v.id)
   order by r.code, p.code, v.size_ml
$$;
drop function shop_bundles();
create function shop_bundles() returns table(code text, name text, description text, price_paise int, items jsonb, in_stock boolean, max_qty int)
language sql stable security definer set search_path = public as $$
  select b.code, b.name, b.description, b.price_paise,
         (select jsonb_agg(jsonb_build_object('sku', v.sku, 'name', p.name, 'qty', bi.quantity))
            from bundle_items bi join variants v on v.id = bi.variant_id join products p on p.id = v.product_id
           where bi.bundle_id = b.id),
         not exists (select 1 from bundle_items bi join variants v on v.id = bi.variant_id
                      where bi.bundle_id = b.id and (v.stock_on_hand - v.stock_reserved) < bi.quantity),
         least(5, _available_for(null, b.code))
    from bundles b
   where b.status = 'published'
     and not exists (select 1 from bundle_items bi join variants v on v.id = bi.variant_id join products p on p.id = v.product_id
                      where bi.bundle_id = b.id and (not v.is_active or p.status <> 'published' or _variant_in_unreleased_launch(v.id)))
$$;
grant execute on function shop_catalogue(), shop_bundles() to anon, authenticated;
