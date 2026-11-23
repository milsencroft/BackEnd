-- Sales and operations report for a date range (India time). Counts paid orders only; refunds are subtracted in the period they were made.
create function admin_report(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare paid text[] := array['captured', 'refund_pending', 'refunded']; res jsonb;
begin
  perform _require('payments.view');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'invalid_range'; end if;
  with o as (
    select * from orders where payment_status::text = any (paid) and (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
  ref as (
    select coalesce(sum(r.amount_paise), 0) amt from refunds r where r.status <> 'failed' and (r.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to)
  select jsonb_build_object(
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'summary', jsonb_build_object(
      'orders', (select count(*) from o), 'gross_paise', (select coalesce(sum(total_paise), 0) from o),
      'discount_paise', (select coalesce(sum(discount_paise), 0) from o), 'tax_paise', (select coalesce(sum(tax_paise), 0) from o),
      'shipping_paise', (select coalesce(sum(shipping_paise), 0) from o), 'refunded_paise', (select amt from ref),
      'net_paise', (select coalesce(sum(total_paise), 0) from o) - (select amt from ref),
      'aov_paise', (select coalesce(round(avg(total_paise))::bigint, 0) from o),
      'customers', (select count(distinct customer_id) from o),
      'repeat_customers', (select count(*) from (select customer_id from orders where payment_status::text = any (paid) group by customer_id having count(*) > 1) x
                            where x.customer_id in (select customer_id from o))),
    'by_type', coalesce((select jsonb_agg(jsonb_build_object('type', t, 'orders', n, 'gross_paise', g)) from (select order_type::text t, count(*) n, sum(total_paise) g from o group by 1) x), '[]'::jsonb),
    'by_launch', coalesce((select jsonb_agg(jsonb_build_object('code', l.code, 'name', l.name, 'orders', x.n, 'gross_paise', x.g) order by x.g desc)
                           from (select launch_id, count(*) n, sum(total_paise) g from o where launch_id is not null group by 1) x join launches l on l.id = x.launch_id), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'orders', n, 'gross_paise', g) order by d)
                       from (select (created_at at time zone 'Asia/Kolkata')::date d, count(*) n, sum(total_paise) g from o group by 1) x), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('name', nm, 'sku', sku, 'units', u, 'revenue_paise', rv) order by rv desc)
                          from (select i.name_snapshot nm, i.sku_snapshot sku, sum(i.quantity) u, sum(i.line_total_paise) rv from order_items i join o on o.id = i.order_id
                                 group by 1, 2 order by sum(i.line_total_paise) desc limit 20) x), '[]'::jsonb),
    'coupons', coalesce((select jsonb_agg(jsonb_build_object('code', c, 'orders', n, 'discount_paise', dsc) order by dsc desc)
                         from (select coupon_code c, count(*) n, sum(discount_paise) dsc from o where coupon_code is not null group by 1) x), '[]'::jsonb),
    'fulfilment', (select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) from (select fulfilment_status::text s, count(*) n from orders where payment_status = 'captured' group by 1) x),
    'launches', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'status', status, 'capacity', capacity, 'allocated', allocated_count) order by created_at desc) from launches where status not in ('draft', 'archived')), '[]'::jsonb),
    'society', coalesce((select jsonb_agg(jsonb_build_object('tier', t.tier, 'name', t.name, 'cap', t.cap, 'active', (select count(*) from society_memberships m where m.tier = t.tier and m.status = 'active')) order by t.tier) from society_tiers t), '[]'::jsonb)
  ) into res;
  return res;
end $$;
revoke execute on function public.admin_report(date, date) from public, anon;
grant execute on function public.admin_report(date, date) to authenticated;
