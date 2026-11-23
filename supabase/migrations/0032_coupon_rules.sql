-- Coupon extras: per-customer limit, maximum discount, product restriction, Society tier restriction.
-- Stacking stays off on purpose: an order takes one coupon code.
alter table coupons
  add column max_per_customer int check (max_per_customer is null or max_per_customer > 0),
  add column max_discount_paise int check (max_discount_paise is null or max_discount_paise > 0),
  add column product_ids uuid[],
  add column tiers int[];

create function admin_set_coupon_rules(p_code text, p_max_per_customer int, p_max_discount_paise int, p_product_ids uuid[], p_tiers int[], p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare before jsonb;
begin
  perform _require('coupons.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if (p_max_per_customer is not null and p_max_per_customer < 1) or (p_max_discount_paise is not null and p_max_discount_paise < 1) then raise exception 'invalid_input'; end if;
  if p_product_ids is not null and (cardinality(p_product_ids) = 0 or exists (select 1 from unnest(p_product_ids) u where not exists (select 1 from products where id = u))) then raise exception 'invalid_input'; end if;
  if p_tiers is not null and (cardinality(p_tiers) = 0 or exists (select 1 from unnest(p_tiers) t where not exists (select 1 from society_tiers where tier = t))) then raise exception 'invalid_input'; end if;
  select jsonb_build_object('max_per_customer', max_per_customer, 'max_discount_paise', max_discount_paise, 'product_ids', product_ids, 'tiers', tiers) into before from coupons where code = upper(trim(p_code));
  if not found then raise exception 'not_found'; end if;
  update coupons set max_per_customer = p_max_per_customer, max_discount_paise = p_max_discount_paise, product_ids = p_product_ids, tiers = p_tiers where code = upper(trim(p_code));
  perform _audit('coupon.rules', 'coupon', upper(trim(p_code)), p_reason, before,
    jsonb_build_object('max_per_customer', p_max_per_customer, 'max_discount_paise', p_max_discount_paise, 'product_ids', p_product_ids, 'tiers', p_tiers));
end $$;
revoke execute on function public.admin_set_coupon_rules(text,int,int,uuid[],int[],text) from public, anon;
grant execute on function public.admin_set_coupon_rules(text,int,int,uuid[],int[],text) to authenticated;

CREATE OR REPLACE FUNCTION public.begin_retail_checkout(p_customer uuid, p_items jsonb, p_address jsonb, p_coupon text DEFAULT NULL::text)
 RETURNS TABLE(r_result text, r_order_id uuid, r_order_number text, r_total_paise integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare it jsonb; rv variants%rowtype; rp products%rowtype; rb bundles%rowtype; cp coupons%rowtype; g record; ln record; x record;
        lines jsonb := '[]'; rates int[] := '{}'; sub int := 0; disc int := 0; ship int := 0; total int; q int; elig int := 0;
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
                                           'sku', rv.sku, 'qty', q, 'unit', rv.price_paise, 'product_id', rp.id);
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
    -- Row lock so two simultaneous checkouts cannot both slip past a per-customer limit.
    select * into cp from coupons
     where code = upper(trim(p_coupon)) and is_active and (starts_at is null or starts_at <= now())
       and (ends_at is null or ends_at >= now()) and (max_uses is null or uses_count < max_uses) and min_order_paise <= sub
       for update;
    if not found then raise exception 'invalid_coupon'; end if;
    if cp.max_per_customer is not null and
       (select count(*) from orders o where o.customer_id = p_customer and o.coupon_code = cp.code
          and o.payment_status in ('created', 'pending', 'captured', 'refund_pending')) >= cp.max_per_customer then
      raise exception 'invalid_coupon'; end if;
    if cp.tiers is not null and not exists (select 1 from society_memberships m where m.customer_id = p_customer and m.status = 'active' and m.tier = any(cp.tiers)) then
      raise exception 'invalid_coupon'; end if;
    if cp.product_ids is not null then
      -- Only lines for the listed products earn the discount; bundles are not eligible for a product-restricted coupon.
      select coalesce(sum((l.unit * l.qty)), 0) into elig
        from jsonb_to_recordset(lines) as l(product_id uuid, qty int, unit int) where l.product_id = any(cp.product_ids);
      if elig = 0 then raise exception 'invalid_coupon'; end if;
    else elig := sub;
    end if;
    disc := case when cp.discount_type = 'percent' then (elig::bigint * cp.value / 100)::int else least(cp.value, elig) end;
    if cp.max_discount_paise is not null then disc := least(disc, cp.max_discount_paise); end if;
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
end $function$;
