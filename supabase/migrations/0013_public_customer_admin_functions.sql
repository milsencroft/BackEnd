-- Migration 0013: public storefront reads, customer actions, and permission-checked admin actions (all audited).
insert into role_permissions (role, permission) values
  ('admin', 'orders.manage'), ('order_manager', 'orders.manage'),
  ('admin', 'payments.refund'),
  ('admin', 'inventory.manage'), ('product_manager', 'inventory.manage'),
  ('admin', 'launches.manage')
on conflict do nothing;

create function _require(p text) returns void language plpgsql stable security definer set search_path = public as $$
begin if not has_permission(p) then raise exception 'forbidden' using errcode = '42501'; end if; end $$;

create function _is_super() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s where s.customer_id = current_customer_id() and s.role = 'super_admin' and s.is_active)
$$;

-- ---------- Public reads (no sign-in needed) ----------
create function public_launch_state(p_code text)
returns table (code text, name text, status launch_status, capacity int, allocated int, held int, remaining int)
language sql stable security definer set search_path = public as $$
  select l.code, l.name, l.status, l.capacity, l.allocated_count, h.n, greatest(l.capacity - l.allocated_count - h.n, 0)
    from launches l
    cross join lateral (select count(*)::int as n from slot_reservations sr
                         where sr.launch_id = l.id and sr.status = 'active' and sr.expires_at > now()) h
   where l.code = p_code and l.status in ('preorder_active', 'closed', 'post_launch_review', 'published_in_shop', 'completed')
$$;

create function launch_catalogue(p_code text)
returns table (sku text, product_code text, product_name text, family text, region_code text, region_name text, story text,
               notes jsonb, images jsonb, size_ml int, launch_price_paise int, regular_price_paise int, in_stock boolean)
language sql stable security definer set search_path = public as $$
  select v.sku, p.code, p.name, p.family, r.code, r.name, p.story, p.notes, p.images, v.size_ml,
         coalesce(lv.launch_price_paise, v.price_paise), v.price_paise, (v.stock_on_hand - v.stock_reserved) > 0
    from launches l
    join launch_variants lv on lv.launch_id = l.id and lv.is_available
    join variants v on v.id = lv.variant_id and v.is_active
    join products p on p.id = v.product_id and p.status in ('approved', 'published')
    join regions r on r.id = p.region_id
   where l.code = p_code and l.status in ('preorder_active', 'closed', 'post_launch_review', 'published_in_shop', 'completed')
   order by r.code
$$;

create function shop_catalogue()
returns table (product_code text, product_name text, family text, region_code text, region_name text, story text, notes jsonb,
               images jsonb, sku text, size_ml int, price_paise int, compare_at_paise int, in_stock boolean)
language sql stable security definer set search_path = public as $$
  select p.code, p.name, p.family, r.code, r.name, p.story, p.notes, p.images, v.sku, v.size_ml, v.price_paise, v.compare_at_paise,
         (v.stock_on_hand - v.stock_reserved) > 0
    from products p
    join regions r on r.id = p.region_id and r.status = 'published'
    join variants v on v.product_id = p.id and v.is_active
   where p.status = 'published' and not _variant_in_unreleased_launch(v.id)
   order by r.code, p.code, v.size_ml
$$;

create function shop_bundles()
returns table (code text, name text, description text, price_paise int, items jsonb, in_stock boolean)
language sql stable security definer set search_path = public as $$
  select b.code, b.name, b.description, b.price_paise,
         (select jsonb_agg(jsonb_build_object('sku', v.sku, 'name', p.name, 'qty', bi.quantity))
            from bundle_items bi join variants v on v.id = bi.variant_id join products p on p.id = v.product_id
           where bi.bundle_id = b.id),
         not exists (select 1 from bundle_items bi join variants v on v.id = bi.variant_id
                      where bi.bundle_id = b.id and (v.stock_on_hand - v.stock_reserved) < bi.quantity)
    from bundles b
   where b.status = 'published'
     and not exists (select 1 from bundle_items bi join variants v on v.id = bi.variant_id join products p on p.id = v.product_id
                      where bi.bundle_id = b.id and (not v.is_active or p.status <> 'published' or _variant_in_unreleased_launch(v.id)))
$$;

-- ---------- Signed-in customer actions ----------
create function my_permissions() returns text[] language plpgsql stable security definer set search_path = public as $$
declare r staff_role;
begin
  select s.role into r from staff s where s.customer_id = current_customer_id() and s.is_active;
  if r is null then return '{}'; end if;
  if r = 'super_admin' then
    return array['customers.view','catalog.manage','media.manage','launches.view','launches.manage','audit.view','orders.view','orders.manage',
                 'payments.view','payments.refund','inventory.view','inventory.manage','coupons.manage','notifications.view','society.view',
                 'society.manage','settings.view','settings.manage','staff.manage'];
  end if;
  return coalesce((select array_agg(permission order by permission) from role_permissions where role = r), '{}');
end $$;

create function my_role() returns text language sql stable security definer set search_path = public as $$
  select s.role::text from staff s where s.customer_id = current_customer_id() and s.is_active
$$;

create function update_my_profile(p_name text, p_phone text, p_whatsapp boolean) returns void
language plpgsql security definer set search_path = public as $$
declare c uuid := current_customer_id(); cur boolean;
begin
  if c is null then raise exception 'not_signed_in'; end if;
  if coalesce(p_phone, '') <> '' and p_phone !~ '^[6-9][0-9]{9}$' then raise exception 'invalid_phone'; end if;
  select whatsapp_consent into cur from customers where id = c;
  update customers set full_name = coalesce(nullif(trim(p_name), ''), full_name), phone = nullif(trim(p_phone), ''),
         whatsapp_consent = coalesce(p_whatsapp, whatsapp_consent),
         whatsapp_consent_at = case when p_whatsapp is true and not cur then now() when p_whatsapp is false then null else whatsapp_consent_at end,
         whatsapp_consent_source = case when p_whatsapp is true and not cur then 'account_page' else whatsapp_consent_source end
   where id = c;
end $$;

create function my_reserve_launch_slot(p_code text) returns table (r_result text, r_expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare c uuid := current_customer_id(); l uuid; r record;
begin
  if c is null then raise exception 'not_signed_in'; end if;
  select id into l from launches where code = p_code;
  if l is null then return query select 'not_found'::text, null::timestamptz; return; end if;
  select * into r from reserve_launch_slot(l, c);
  return query select r.r_result, r.r_expires_at;
end $$;

-- ---------- Admin actions: permission-checked here AND in RLS, each writes audit_log ----------
create function admin_summary() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('orders.view');
  return jsonb_build_object(
    'orders_paid', (select count(*) from orders where payment_status = 'captured'),
    'revenue_paise', (select coalesce(sum(total_paise), 0) from orders where payment_status = 'captured'),
    'to_pack', (select count(*) from orders where payment_status = 'captured' and fulfilment_status in ('unfulfilled', 'processing')),
    'refunds_pending', (select count(*) from orders where payment_status = 'refund_pending'));
end $$;

create function admin_set_region_status(p_region uuid, p_status region_status, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old region_status;
begin
  perform _require('catalog.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select status into old from regions where id = p_region for update;
  if not found then raise exception 'not_found'; end if;
  update regions set status = p_status where id = p_region;
  perform _audit('region.status', 'region', p_region::text, p_reason, to_jsonb(old), to_jsonb(p_status));
end $$;

create function admin_set_product_status(p_product uuid, p_status product_status, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old product_status; reg region_status;
begin
  perform _require('catalog.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select p.status, r.status into old, reg from products p join regions r on r.id = p.region_id where p.id = p_product for update of p;
  if not found then raise exception 'not_found'; end if;
  if p_status = 'published' then
    if reg <> 'published' then raise exception 'region_not_published'; end if;
    if not exists (select 1 from variants where product_id = p_product and is_active) then raise exception 'no_active_variant'; end if;
  end if;
  update products set status = p_status where id = p_product;
  perform _audit('product.status', 'product', p_product::text, p_reason, to_jsonb(old), to_jsonb(p_status));
end $$;

create function admin_update_variant(p_variant uuid, p_price_paise int, p_compare_at_paise int, p_is_active boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old variants%rowtype;
begin
  perform _require('catalog.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into old from variants where id = p_variant for update;
  if not found then raise exception 'not_found'; end if;
  update variants set price_paise = p_price_paise, compare_at_paise = p_compare_at_paise, is_active = p_is_active where id = p_variant;
  perform _audit('variant.update', 'variant', p_variant::text, p_reason,
    jsonb_build_object('price_paise', old.price_paise, 'compare_at_paise', old.compare_at_paise, 'is_active', old.is_active),
    jsonb_build_object('price_paise', p_price_paise, 'compare_at_paise', p_compare_at_paise, 'is_active', p_is_active));
end $$;

create function admin_set_launch_price(p_launch uuid, p_variant uuid, p_price_paise int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old int;
begin
  perform _require('launches.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select launch_price_paise into old from launch_variants where launch_id = p_launch and variant_id = p_variant for update;
  if not found then raise exception 'not_found'; end if;
  update launch_variants set launch_price_paise = p_price_paise where launch_id = p_launch and variant_id = p_variant;
  perform _audit('launch.price', 'launch', p_launch::text, p_reason, to_jsonb(old), to_jsonb(p_price_paise));
end $$;

create function admin_set_launch_status(p_launch uuid, p_status launch_status, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare l launches%rowtype;
begin
  perform _require('launches.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into l from launches where id = p_launch for update;
  if not found then raise exception 'not_found'; end if;
  if l.status in ('cancelled', 'archived') then raise exception 'launch_final'; end if;
  if l.allocated_count >= l.capacity and p_status = 'preorder_active' then raise exception 'launch_full'; end if;
  if p_status = 'preorder_active' then
    if not exists (select 1 from launch_variants lv where lv.launch_id = p_launch and lv.is_available) then raise exception 'launch_not_ready'; end if;
    if exists (select 1 from launch_variants lv join variants v on v.id = lv.variant_id join products p on p.id = v.product_id
                where lv.launch_id = p_launch and p.status not in ('approved', 'published')) then raise exception 'launch_not_ready'; end if;
  end if;
  update launches set status = p_status,
         published_at = case when p_status = 'preorder_active' then coalesce(published_at, now()) else published_at end,
         approved_by = case when p_status = 'preorder_active' then current_customer_id() else approved_by end,
         closed_at = case when p_status = 'closed' then now() else closed_at end,
         closed_reason = case when p_status = 'closed' then p_reason else closed_reason end
   where id = p_launch;
  perform _audit('launch.status', 'launch', p_launch::text, p_reason, to_jsonb(l.status), to_jsonb(p_status));
end $$;

create function admin_set_launch_capacity(p_launch uuid, p_capacity int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare l launches%rowtype;
begin
  perform _require('launches.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into l from launches where id = p_launch for update;
  if not found then raise exception 'not_found'; end if;
  if p_capacity < l.allocated_count or p_capacity < 1 then raise exception 'below_allocated'; end if;
  update launches set capacity = p_capacity where id = p_launch;
  perform _audit('launch.capacity', 'launch', p_launch::text, p_reason, to_jsonb(l.capacity), to_jsonb(p_capacity));
end $$;

create function admin_adjust_stock(p_variant uuid, p_delta int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v variants%rowtype;
begin
  perform _require('inventory.manage');
  if coalesce(trim(p_reason), '') = '' or p_delta = 0 then raise exception 'reason_required'; end if;
  select * into v from variants where id = p_variant for update;
  if not found then raise exception 'not_found'; end if;
  if v.stock_on_hand + p_delta < v.stock_reserved then raise exception 'below_reserved'; end if;
  update variants set stock_on_hand = stock_on_hand + p_delta where id = p_variant;
  insert into inventory_movements (variant_id, movement, quantity, reason, actor_customer_id)
  values (p_variant, case when p_delta > 0 then 'restock' else 'adjust' end, abs(p_delta), p_reason, current_customer_id());
  perform _audit('stock.adjust', 'variant', p_variant::text, p_reason, to_jsonb(v.stock_on_hand), to_jsonb(v.stock_on_hand + p_delta));
end $$;

create function admin_set_fulfilment(p_order uuid, p_status fulfilment_status, p_courier text default null, p_tracking text default null, p_note text default null) returns void
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
     or (o.fulfilment_status = 'shipped' and p_status in ('delivered', 'returned'))
     or (o.fulfilment_status = 'delivered' and p_status = 'returned');
  if not ok then raise exception 'invalid_transition'; end if;
  if p_status = 'shipped' and (coalesce(trim(p_courier), '') = '' or coalesce(trim(p_tracking), '') = '') then
    raise exception 'tracking_required'; end if;
  update orders set fulfilment_status = p_status, courier = coalesce(nullif(trim(p_courier), ''), courier),
         tracking_number = coalesce(nullif(trim(p_tracking), ''), tracking_number) where id = p_order;
  perform _hist(p_order, 'fulfilment', o.fulfilment_status::text, p_status::text, p_note);
  perform _audit('order.fulfilment', 'order', p_order::text, p_note, to_jsonb(o.fulfilment_status), to_jsonb(p_status));
  if p_status = 'shipped' then
    select email into v_email from customers where id = o.customer_id;
    perform _enqueue('order_shipped:' || p_order, 'email', v_email, 'order_shipped',
      jsonb_build_object('order_number', o.order_number, 'courier', p_courier, 'tracking_number', p_tracking));
  end if;
end $$;

create function admin_update_setting(p_key text, p_value jsonb, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old jsonb;
begin
  perform _require('settings.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_key = 'gst' then
    if jsonb_typeof(p_value->'enabled') <> 'boolean' or (p_value->>'mode') not in ('inclusive', 'exclusive')
       or (p_value->>'default_rate_bps')::int not between 0 and 10000 or (p_value->>'seller_state_code') !~ '^[0-9]{2}$' then
      raise exception 'invalid_setting'; end if;
  elsif p_key = 'shipping' then
    if (p_value->>'flat_paise')::int < 0 then raise exception 'invalid_setting'; end if;
  else raise exception 'invalid_setting';
  end if;
  select value into old from store_settings where key = p_key for update;
  update store_settings set value = p_value, updated_by = current_customer_id() where key = p_key;
  perform _audit('setting.' || p_key, 'store_settings', p_key, p_reason, old, p_value);
end $$;

create function admin_list_staff() returns table (customer_id uuid, email text, full_name text, role staff_role, is_active boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('staff.manage');
  return query select s.customer_id, c.email, c.full_name, s.role, s.is_active from staff s join customers c on c.id = s.customer_id order by s.created_at;
end $$;

create function admin_grant_staff(p_email text, p_role staff_role, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  perform _require('staff.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_role = 'super_admin' and not _is_super() then raise exception 'forbidden' using errcode = '42501'; end if;
  select id into c from customers where lower(email) = lower(trim(p_email)) and is_active order by created_at limit 1;
  if c is null then raise exception 'customer_not_found'; end if;
  insert into staff (customer_id, role, is_active, granted_by) values (c, p_role, true, current_customer_id())
  on conflict (customer_id) do update set role = excluded.role, is_active = true, granted_by = excluded.granted_by;
  perform _audit('staff.grant', 'customer', c::text, p_reason, null, to_jsonb(p_role));
end $$;

create function admin_revoke_staff(p_customer uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare r staff_role;
begin
  perform _require('staff.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_customer = current_customer_id() then raise exception 'cannot_revoke_self'; end if;
  select role into r from staff where customer_id = p_customer and is_active for update;
  if not found then raise exception 'not_found'; end if;
  if r = 'super_admin' then
    if not _is_super() then raise exception 'forbidden' using errcode = '42501'; end if;
    if (select count(*) from staff where role = 'super_admin' and is_active) < 2 then raise exception 'last_super_admin'; end if;
  end if;
  update staff set is_active = false where customer_id = p_customer;
  perform _audit('staff.revoke', 'customer', p_customer::text, p_reason, to_jsonb(r), null);
end $$;

create function admin_set_tier(p_tier int, p_cap int, p_name text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old society_tiers%rowtype;
begin
  perform _require('society.manage');
  if coalesce(trim(p_reason), '') = '' or p_cap < 1 or coalesce(trim(p_name), '') = '' then raise exception 'invalid_setting'; end if;
  select * into old from society_tiers where tier = p_tier for update;
  if not found then raise exception 'not_found'; end if;
  update society_tiers set cap = p_cap, name = trim(p_name) where tier = p_tier;
  perform _audit('society.tier', 'society_tier', p_tier::text, p_reason, jsonb_build_object('cap', old.cap, 'name', old.name),
                 jsonb_build_object('cap', p_cap, 'name', trim(p_name)));
end $$;

do $$
declare f text;
begin
  foreach f in array array['_require(text)', '_is_super()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['public_launch_state(text)', 'launch_catalogue(text)', 'shop_catalogue()', 'shop_bundles()'] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated, service_role', f);
  end loop;
  foreach f in array array[
    'my_permissions()', 'my_role()', 'update_my_profile(text,text,boolean)', 'my_reserve_launch_slot(text)', 'admin_summary()',
    'admin_set_region_status(uuid,region_status,text)', 'admin_set_product_status(uuid,product_status,text)',
    'admin_update_variant(uuid,int,int,boolean,text)', 'admin_set_launch_price(uuid,uuid,int,text)',
    'admin_set_launch_status(uuid,launch_status,text)', 'admin_set_launch_capacity(uuid,int,text)', 'admin_adjust_stock(uuid,int,text)',
    'admin_set_fulfilment(uuid,fulfilment_status,text,text,text)', 'admin_update_setting(text,jsonb,text)', 'admin_list_staff()',
    'admin_grant_staff(text,staff_role,text)', 'admin_revoke_staff(uuid,text)', 'admin_set_tier(int,int,text,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
