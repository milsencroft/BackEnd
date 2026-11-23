-- 0033: server-side cart, and read functions so the browser never queries tables directly.

-- ---------------------------------------------------------------- cart
create table carts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid unique references customers(id) on delete cascade,
  guest_token text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (customer_id is not null or (guest_token is not null and length(guest_token) >= 32))
);
create table cart_lines (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references carts(id) on delete cascade,
  item_key text not null,
  sku text,
  bundle_code text,
  qty int not null check (qty between 1 and 5),
  created_at timestamptz not null default now(),
  unique (cart_id, item_key),
  check ((sku is not null) <> (bundle_code is not null))
);
alter table carts enable row level security;
alter table cart_lines enable row level security;
revoke all on carts, cart_lines from anon, authenticated;

-- Finds (and optionally creates) the cart for a signed-in customer or a guest token.
create or replace function _cart_id(p_customer uuid, p_guest text, p_create boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  if p_customer is not null then
    select id into c from carts where customer_id = p_customer;
    if c is null and p_create then insert into carts (customer_id) values (p_customer) on conflict (customer_id) do nothing; select id into c from carts where customer_id = p_customer; end if;
  elsif p_guest is not null and length(p_guest) >= 32 then
    select id into c from carts where guest_token = p_guest;
    if c is null and p_create then insert into carts (guest_token) values (p_guest) on conflict (guest_token) do nothing; select id into c from carts where guest_token = p_guest; end if;
  end if;
  return c;
end $$;

-- Add an item. The database decides whether it can be bought and how many fit.
create or replace function cart_add(p_customer uuid, p_guest text, p_sku text, p_bundle text, p_qty int) returns text
language plpgsql security definer set search_path = public as $$
declare c uuid; key text; rv variants%rowtype; rp products%rowtype; rb bundles%rowtype; x record; n int;
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
  c := _cart_id(p_customer, p_guest, true);
  if c is null then return 'invalid_cart'; end if;
  select count(*) into n from cart_lines where cart_id = c and item_key <> key;
  if n >= 10 then return 'cart_full'; end if;
  insert into cart_lines (cart_id, item_key, sku, bundle_code, qty) values (c, key, p_sku, p_bundle, p_qty)
  on conflict (cart_id, item_key) do update set qty = least(5, cart_lines.qty + excluded.qty);
  update carts set updated_at = now() where id = c;
  return 'ok';
end $$;

create or replace function cart_set_qty(p_customer uuid, p_guest text, p_sku text, p_bundle text, p_qty int) returns text
language plpgsql security definer set search_path = public as $$
declare c uuid; key text;
begin
  if (p_sku is null) = (p_bundle is null) or p_qty is null then return 'invalid_item'; end if;
  key := case when p_sku is not null then 'sku:' || p_sku else 'bundle:' || p_bundle end;
  c := _cart_id(p_customer, p_guest, false);
  if c is null then return 'not_found'; end if;
  update cart_lines set qty = greatest(1, least(5, p_qty)) where cart_id = c and item_key = key;
  if not found then return 'not_found'; end if;
  update carts set updated_at = now() where id = c;
  return 'ok';
end $$;

create or replace function cart_remove(p_customer uuid, p_guest text, p_sku text, p_bundle text) returns void
language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  c := _cart_id(p_customer, p_guest, false);
  if c is null then return; end if;
  delete from cart_lines where cart_id = c and item_key = case when p_sku is not null then 'sku:' || p_sku else 'bundle:' || p_bundle end;
  update carts set updated_at = now() where id = c;
end $$;

create or replace function cart_clear(p_customer uuid, p_guest text) returns void
language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  c := _cart_id(p_customer, p_guest, false);
  if c is not null then delete from cart_lines where cart_id = c; update carts set updated_at = now() where id = c; end if;
end $$;

-- What the cart page shows. Names, prices and availability come from the catalogue, never from the browser.
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

-- Items for checkout, taken from the stored cart (the browser sends no items).
create or replace function cart_items_json(p_customer uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(case when cl.sku is not null then jsonb_build_object('sku', cl.sku, 'qty', cl.qty)
                                  else jsonb_build_object('bundle', cl.bundle_code, 'qty', cl.qty) end order by cl.created_at), '[]')
    from cart_lines cl join carts c on c.id = cl.cart_id where c.customer_id = p_customer
$$;

-- After sign-in the guest cart joins the customer's cart.
create or replace function cart_merge(p_customer uuid, p_guest text) returns void
language plpgsql security definer set search_path = public as $$
declare g uuid; c uuid; r record; n int;
begin
  if p_guest is null or length(p_guest) < 32 then return; end if;
  select id into g from carts where guest_token = p_guest;
  if g is null then return; end if;
  c := _cart_id(p_customer, null, true);
  for r in select * from cart_lines where cart_id = g order by created_at loop
    select count(*) into n from cart_lines where cart_id = c and item_key <> r.item_key;
    if n < 10 then
      insert into cart_lines (cart_id, item_key, sku, bundle_code, qty) values (c, r.item_key, r.sku, r.bundle_code, r.qty)
      on conflict (cart_id, item_key) do update set qty = least(5, cart_lines.qty + excluded.qty);
    end if;
  end loop;
  delete from carts where id = g;
end $$;

revoke all on function _cart_id(uuid, text, boolean), cart_add(uuid, text, text, text, int), cart_set_qty(uuid, text, text, text, int),
  cart_remove(uuid, text, text, text), cart_clear(uuid, text), cart_view(uuid, text), cart_items_json(uuid), cart_merge(uuid, text)
  from public, anon, authenticated;
grant execute on function _cart_id(uuid, text, boolean), cart_add(uuid, text, text, text, int), cart_set_qty(uuid, text, text, text, int),
  cart_remove(uuid, text, text, text), cart_clear(uuid, text), cart_view(uuid, text), cart_items_json(uuid), cart_merge(uuid, text) to service_role;

-- ---------------------------------------------------------------- reads for the signed-in customer
create or replace function my_orders() returns table(id uuid, order_number text, order_type text, total_paise int, payment_status text, fulfilment_status text,
  courier text, tracking_number text, tracking_url text, estimated_delivery date, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_number, o.order_type::text, o.total_paise, o.payment_status::text, o.fulfilment_status::text, o.courier, o.tracking_number, o.tracking_url, o.estimated_delivery, o.created_at
    from orders o where o.customer_id = current_customer_id() order by o.created_at desc
$$;
create or replace function my_profile() returns table(full_name text, phone text, whatsapp_consent boolean)
language sql stable security definer set search_path = public as $$
  select c.full_name, c.phone, c.whatsapp_consent from customers c where c.id = current_customer_id()
$$;
create or replace function my_addresses() returns table(id uuid, label text, recipient text, phone text, line1 text, line2 text, city text, state text, pincode text, is_default boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.label, a.recipient, a.phone, a.line1, a.line2, a.city, a.state, a.pincode, a.is_default from customer_addresses a where a.customer_id = current_customer_id() order by a.created_at
$$;
create or replace function my_wishlist() returns table(product_code text)
language sql stable security definer set search_path = public as $$
  select w.product_code from wishlist_items w where w.customer_id = current_customer_id() order by w.created_at desc
$$;
create or replace function my_order_status(p_order uuid) returns text
language sql stable security definer set search_path = public as $$
  select o.payment_status::text from orders o where o.id = p_order and o.customer_id = current_customer_id()
$$;
create or replace function public_society_tiers() returns table(tier int, name text, benefits text)
language sql stable security definer set search_path = public as $$ select t.tier, t.name, t.benefits from society_tiers t order by t.tier $$;

-- ---------------------------------------------------------------- reads for staff
create or replace function admin_launch_list() returns table(id uuid, code text, name text, status text, capacity int)
language plpgsql stable security definer set search_path = public as $$
begin perform _require('launches.view');
  return query select l.id, l.code, l.name, l.status::text, l.capacity from launches l order by l.created_at; end $$;
create or replace function admin_get_setting(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin perform _require('settings.view'); select value into v from store_settings where key = p_key; return v; end $$;
create or replace function admin_product_names() returns table(id uuid, code text, name text)
language plpgsql stable security definer set search_path = public as $$
begin perform _require('coupons.manage'); return query select p.id, p.code, p.name from products p order by p.code; end $$;
create or replace function admin_tier_numbers() returns table(tier int)
language plpgsql stable security definer set search_path = public as $$
begin perform _require('coupons.manage'); return query select t.tier from society_tiers t order by t.tier; end $$;

revoke all on function my_orders(), my_profile(), my_addresses(), my_wishlist(), my_order_status(uuid), public_society_tiers(),
  admin_launch_list(), admin_get_setting(text), admin_product_names(), admin_tier_numbers() from public, anon;
grant execute on function my_orders(), my_profile(), my_addresses(), my_wishlist(), my_order_status(uuid), admin_launch_list(), admin_get_setting(text), admin_product_names(), admin_tier_numbers() to authenticated;
grant execute on function public_society_tiers() to anon, authenticated;
