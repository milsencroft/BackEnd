-- What the shop and product pages show: the best live offer open to everyone for each size, with the sale price worked out here.
create function public_offers() returns table(sku text, title text, kind text, label text, sale_price_paise int, ends_at timestamptz)
language sql stable security definer set search_path = public as $$
  select distinct on (v.sku) v.sku, o.title, o.kind,
    case o.type when 'percent' then o.value || '% off'
                when 'flat' then '₹' || trim(trailing '.' from trim(trailing '0' from (o.value / 100.0)::numeric(12, 2)::text)) || ' off'
                else 'Buy ' || o.buy_qty || ', get ' || o.get_qty || ' free' end,
    case o.type when 'percent' then v.price_paise - (v.price_paise::bigint * o.value / 100)::int
                when 'flat' then greatest(v.price_paise - o.value, 0) end,
    o.ends_at
    from variants v
    join products p on p.id = v.product_id and p.status = 'published'
    join offers o on o.is_active and o.audience = 'everyone' and (o.starts_at is null or o.starts_at <= now()) and (o.ends_at is null or o.ends_at >= now())
                 and (o.scope = 'all' or (o.scope = 'products' and p.id = any(o.product_ids)) or (o.scope = 'regions' and p.region_id = any(o.region_ids)))
   where v.is_active and not _variant_in_unreleased_launch(v.id)
   order by v.sku, (case o.type when 'percent' then o.value::numeric / 100 when 'flat' then least(o.value, v.price_paise)::numeric / v.price_paise
                                else o.get_qty::numeric / (o.buy_qty + o.get_qty) end) desc
$$;
revoke execute on function public_offers() from public;
grant execute on function public_offers() to anon, authenticated, service_role;
