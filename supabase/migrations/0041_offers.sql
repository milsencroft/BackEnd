-- Migration 0041: automatic offers (sales, clearance, buy X get Y, member and new-customer offers).
-- Offers are applied by the database at checkout and previewed in the cart. The browser never sends a price or a discount.
-- One best offer per cart line. Offers and coupons combine only when the offer allows it. Bundles and launch pre-orders are not discounted.

create table offers (
  id                 uuid primary key default gen_random_uuid(),
  title              text not null check (char_length(title) between 3 and 80),
  kind               text not null default 'sale' check (kind in ('sale', 'clearance', 'bogo', 'festive', 'member', 'new_customer')),
  type               text not null check (type in ('percent', 'flat', 'buy_get')),
  value              int check (value is null or value > 0),
  buy_qty            int check (buy_qty is null or buy_qty >= 1),
  get_qty            int check (get_qty is null or get_qty >= 1),
  scope              text not null default 'products' check (scope in ('all', 'products', 'regions')),
  product_ids        uuid[],
  region_ids         uuid[],
  audience           text not null default 'everyone' check (audience in ('everyone', 'new_customers', 'returning_customers', 'society_members')),
  tiers              int[],
  starts_at          timestamptz,
  ends_at            timestamptz,
  stack_with_coupons boolean not null default false,
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  check (type <> 'percent' or value between 1 and 100),
  check (type <> 'flat' or value is not null),
  check (type <> 'buy_get' or (buy_qty is not null and get_qty is not null and buy_qty + get_qty <= 5)),
  check (scope <> 'products' or coalesce(cardinality(product_ids), 0) > 0),
  check (scope <> 'regions' or coalesce(cardinality(region_ids), 0) > 0),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);
alter table offers enable row level security;
create policy offers_staff on offers for all using (has_permission('coupons.manage')) with check (has_permission('coupons.manage'));

alter table orders add column offer_discount_paise int not null default 0, add column offer_labels text[];

-- p_lines: [{product_id, qty, unit}] for product lines. Returns the total offer discount, the offers that won, and whether coupons are blocked.
create function offer_discount(p_customer uuid, p_lines jsonb) returns table(r_discount int, r_labels text[], r_blocks boolean)
language plpgsql stable security definer set search_path = public as $$
declare l record; f record; best int; bl text; bb boolean; d int; grp int; tot int := 0; labels text[] := '{}'; blocks boolean := false;
begin
  for l in select * from jsonb_to_recordset(coalesce(p_lines, '[]')) as x(product_id uuid, qty int, unit int) where x.product_id is not null loop
    best := 0; bl := null; bb := false;
    for f in
      select o.* from offers o
       where o.is_active and (o.starts_at is null or o.starts_at <= now()) and (o.ends_at is null or o.ends_at >= now())
         and (o.scope = 'all'
              or (o.scope = 'products' and l.product_id = any(o.product_ids))
              or (o.scope = 'regions' and exists (select 1 from products p where p.id = l.product_id and p.region_id = any(o.region_ids))))
         and (o.audience = 'everyone' or (p_customer is not null and (
               (o.audience = 'new_customers' and not exists (select 1 from orders x where x.customer_id = p_customer and x.payment_status in ('captured', 'refund_pending')))
            or (o.audience = 'returning_customers' and exists (select 1 from orders x where x.customer_id = p_customer and x.payment_status in ('captured', 'refund_pending')))
            or (o.audience = 'society_members' and exists (select 1 from society_memberships m where m.customer_id = p_customer and m.status = 'active' and (o.tiers is null or m.tier = any(o.tiers)))))))
    loop
      if f.type = 'percent' then d := (l.unit::bigint * l.qty * f.value / 100)::int;
      elsif f.type = 'flat' then d := least(f.value, l.unit) * l.qty;
      else grp := f.buy_qty + f.get_qty; d := ((l.qty / grp) * f.get_qty + greatest(0, (l.qty % grp) - f.buy_qty)) * l.unit;
      end if;
      if d > best then best := d; bl := f.title; bb := not f.stack_with_coupons; end if;
    end loop;
    if best > 0 then tot := tot + best; labels := labels || bl; blocks := blocks or bb; end if;
  end loop;
  return query select tot, (select coalesce(array_agg(distinct u), '{}') from unnest(labels) u), blocks;
end $$;
revoke execute on function offer_discount(uuid, jsonb) from public, anon, authenticated;
grant execute on function offer_discount(uuid, jsonb) to service_role;

create function cart_offer_preview(p_customer uuid, p_guest text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; lines jsonb; r record;
begin
  v := cart_view(p_customer, p_guest);
  select coalesce(jsonb_agg(jsonb_build_object('product_id', va.product_id, 'qty', (x->>'qty')::int, 'unit', (x->>'unit_paise')::int)), '[]') into lines
    from jsonb_array_elements(v->'lines') x join variants va on va.sku = x->>'sku' where (x->>'ok')::boolean;
  select * into r from offer_discount(p_customer, lines);
  return jsonb_build_object('offer_discount_paise', r.r_discount, 'offer_labels', to_jsonb(r.r_labels), 'offers_block_coupon', r.r_blocks);
end $$;
revoke execute on function cart_offer_preview(uuid, text) from public, anon, authenticated;
grant execute on function cart_offer_preview(uuid, text) to service_role;

-- Retail checkout applies offers first; a coupon then works on what is left (unless the offer blocks coupons).
create function _patch_function(p_sig text, p_old text, p_new text) returns void
language plpgsql as $$
declare d text; n text;
begin
  d := pg_get_functiondef(p_sig::regprocedure); n := replace(d, p_old, p_new);
  if n = d then raise exception 'patch_not_applied: % / %', p_sig, left(p_old, 60); end if;
  execute n;
end $$;
select _patch_function('begin_retail_checkout(uuid,jsonb,jsonb,text)', 'oid uuid; onum text; s jsonb; rate int; n_rates int; min_rate int;',
  'oid uuid; onum text; s jsonb; rate int; n_rates int; min_rate int; od int := 0; ob boolean := false; ol text[] := ''{}'';');
select _patch_function('begin_retail_checkout(uuid,jsonb,jsonb,text)', 'if coalesce(trim(p_coupon), '''') <> '''' then',
  'select r_discount, r_labels, r_blocks into od, ol, ob from offer_discount(p_customer, lines);
  ol := coalesce(ol, ''{}'');
  if ob and coalesce(trim(p_coupon), '''') <> '''' then raise exception ''invalid_coupon''; end if;
  if coalesce(trim(p_coupon), '''') <> '''' then');
select _patch_function('begin_retail_checkout(uuid,jsonb,jsonb,text)', 'else elig := sub;', 'else elig := sub - od;');
select _patch_function('begin_retail_checkout(uuid,jsonb,jsonb,text)', 'select value into s from store_settings where key = ''shipping'';',
  'disc := least(disc, sub - od) + od;
  select value into s from store_settings where key = ''shipping'';');
select _patch_function('begin_retail_checkout(uuid,jsonb,jsonb,text)', 'perform _hist(oid, ''payment'', null, ''created'');',
  'update orders set offer_discount_paise = od, offer_labels = nullif(ol, ''{}'') where id = oid;
  perform _hist(oid, ''payment'', null, ''created'');');
drop function _patch_function(text, text, text);

-- Admin
create function admin_offer_choices() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('coupons.manage');
  return jsonb_build_object(
    'products', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'region_id', p.region_id, 'region', r.name, 'available', s.n) order by p.code)
                            from products p join regions r on r.id = p.region_id
                            join lateral (select coalesce(sum(greatest(v.stock_on_hand - v.stock_reserved, 0)), 0)::int n from variants v where v.product_id = p.id and v.is_active) s on true
                           where p.status = 'published' and s.n > 0), '[]'),
    'regions', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.name) from regions r where r.status = 'published'), '[]'),
    'tiers', coalesce((select jsonb_agg(t.tier order by t.tier) from society_tiers t), '[]'));
end $$;

create function admin_list_offers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('coupons.manage');
  return coalesce((select jsonb_agg(to_jsonb(o) || jsonb_build_object(
      'product_names', (select coalesce(jsonb_agg(p.name order by p.name), '[]') from products p where p.id = any(o.product_ids)),
      'region_names', (select coalesce(jsonb_agg(r.name order by r.name), '[]') from regions r where r.id = any(o.region_ids)),
      'used', (select count(*) from orders x where x.offer_labels @> array[o.title] and x.payment_status in ('captured', 'refund_pending', 'refunded')))
    order by o.created_at desc) from offers o), '[]');
end $$;

create function admin_save_offer(p_id uuid, p_title text, p_kind text, p_type text, p_value int, p_buy_qty int, p_get_qty int, p_scope text,
  p_product_ids uuid[], p_region_ids uuid[], p_audience text, p_tiers int[], p_starts_at timestamptz, p_ends_at timestamptz, p_stack boolean, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; before jsonb;
begin
  perform _require('coupons.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_scope = 'products' and (coalesce(cardinality(p_product_ids), 0) = 0 or exists (select 1 from unnest(p_product_ids) u where not exists (select 1 from products where id = u))) then raise exception 'invalid_input'; end if;
  if p_scope = 'regions' and (coalesce(cardinality(p_region_ids), 0) = 0 or exists (select 1 from unnest(p_region_ids) u where not exists (select 1 from regions where id = u))) then raise exception 'invalid_input'; end if;
  if p_tiers is not null and (cardinality(p_tiers) = 0 or exists (select 1 from unnest(p_tiers) t where not exists (select 1 from society_tiers where tier = t))) then raise exception 'invalid_input'; end if;
  begin
    if p_id is null then
      insert into offers (title, kind, type, value, buy_qty, get_qty, scope, product_ids, region_ids, audience, tiers, starts_at, ends_at, stack_with_coupons)
      values (trim(p_title), p_kind, p_type, case when p_type = 'buy_get' then null else p_value end, case when p_type = 'buy_get' then p_buy_qty end, case when p_type = 'buy_get' then p_get_qty end,
              p_scope, case when p_scope = 'products' then p_product_ids end, case when p_scope = 'regions' then p_region_ids end,
              p_audience, case when p_audience = 'society_members' then p_tiers end, p_starts_at, p_ends_at, coalesce(p_stack, false)) returning id into rid;
    else
      select to_jsonb(o) into before from offers o where id = p_id;
      if before is null then raise exception 'not_found'; end if;
      update offers set title = trim(p_title), kind = p_kind, type = p_type, value = case when p_type = 'buy_get' then null else p_value end,
             buy_qty = case when p_type = 'buy_get' then p_buy_qty end, get_qty = case when p_type = 'buy_get' then p_get_qty end, scope = p_scope,
             product_ids = case when p_scope = 'products' then p_product_ids end, region_ids = case when p_scope = 'regions' then p_region_ids end,
             audience = p_audience, tiers = case when p_audience = 'society_members' then p_tiers end, starts_at = p_starts_at, ends_at = p_ends_at,
             stack_with_coupons = coalesce(p_stack, false)
       where id = p_id returning id into rid;
    end if;
  exception when check_violation or not_null_violation then raise exception 'invalid_input'; end;
  perform _audit(case when p_id is null then 'offer.create' else 'offer.update' end, 'offer', rid::text, p_reason, before, (select to_jsonb(o) from offers o where id = rid));
  return rid;
end $$;

create function admin_set_offer_active(p_id uuid, p_active boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare was boolean;
begin
  perform _require('coupons.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select is_active into was from offers where id = p_id;
  if not found then raise exception 'not_found'; end if;
  update offers set is_active = p_active where id = p_id;
  perform _audit('offer.active', 'offer', p_id::text, p_reason, to_jsonb(was), to_jsonb(p_active));
end $$;

do $$
declare f text;
begin
  foreach f in array array['admin_offer_choices()', 'admin_list_offers()',
    'admin_save_offer(uuid,text,text,text,int,int,int,text,uuid[],uuid[],text,int[],timestamptz,timestamptz,boolean,text)', 'admin_set_offer_active(uuid,boolean,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
