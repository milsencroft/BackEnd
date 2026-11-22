-- Order IDs follow the master prompt format MC-ORD-YYYY-NNNNN (existing numbers are untouched; none exist yet).
alter table orders alter column order_number set default ('MC-ORD-' || to_char(now() at time zone 'Asia/Kolkata', 'YYYY') || '-' || lpad(nextval('order_number_seq')::text, 5, '0'));

create table order_notes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete restrict,
  author_customer_id uuid references customers(id),
  note text not null check (length(trim(note)) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index on order_notes (order_id, created_at);
alter table order_notes enable row level security;
revoke all on order_notes from anon, authenticated;  -- internal notes are reachable only through the permission-checked functions below

create function admin_add_order_note(p_order uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require('orders.manage');
  if not exists (select 1 from orders where id = p_order) then raise exception 'not_found'; end if;
  insert into order_notes (order_id, author_customer_id, note) values (p_order, current_customer_id(), trim(p_note));
  perform _audit('order.note', 'order', p_order::text, 'internal note added', null, null);
end $$;

create function admin_order_detail(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o orders%rowtype; r jsonb;
begin
  perform _require('orders.view');
  select * into o from orders where id = p_order;
  if not found then raise exception 'not_found'; end if;
  select jsonb_build_object(
    'order', to_jsonb(o) - 'stock_held',
    'customer', (select jsonb_build_object('internal_id', c.id, 'name', c.full_name, 'email', c.email, 'phone', c.phone, 'whatsapp_consent', c.whatsapp_consent) from customers c where c.id = o.customer_id),
    'launch', (select jsonb_build_object('code', l.code, 'name', l.name) from launches l where l.id = o.launch_id),
    'items', coalesce((select jsonb_agg(to_jsonb(i) - 'order_id' order by i.id) from order_items i where i.order_id = o.id), '[]'),
    'payment', (select jsonb_build_object('id', p.id, 'status', p.status, 'razorpay_order_id', p.razorpay_order_id, 'razorpay_payment_id', p.razorpay_payment_id, 'amount_paise', p.amount_paise, 'failure_reason', p.failure_reason, 'updated_at', p.updated_at)
                from payments p where p.order_id = o.id order by p.created_at desc limit 1),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('status', f.status, 'amount_paise', f.amount_paise, 'reason', f.reason, 'created_at', f.created_at) order by f.created_at)
                from refunds f join payments p on p.id = f.payment_id where p.order_id = o.id), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'from', h.from_status, 'to', h.to_status, 'note', h.note, 'at', h.created_at) order by h.id)
                from order_status_history h where h.order_id = o.id), '[]'),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('note', n.note, 'by', (select full_name from customers where id = n.author_customer_id), 'at', n.created_at) order by n.created_at)
                from order_notes n where n.order_id = o.id), '[]')
  ) into r;
  return r;
end $$;

create function admin_search_orders(p_q text default null, p_payment payment_status default null, p_fulfilment fulfilment_status default null,
  p_type order_type default null, p_from date default null, p_to date default null, p_limit int default 25, p_offset int default 0)
returns table (id uuid, order_number text, created_at timestamptz, customer_name text, phone text, order_type order_type, items text,
  total_paise int, payment_status payment_status, fulfilment_status fulfilment_status, courier text, tracking_number text, total_count bigint)
language plpgsql stable security definer set search_path = public as $$
declare q text := nullif(trim(coalesce(p_q, '')), '');
begin
  perform _require('orders.view');
  return query
  select o.id, o.order_number, o.created_at, c.full_name, coalesce(c.phone, o.shipping_address->>'phone'), o.order_type,
         (select string_agg(i.name_snapshot || ' x' || i.quantity, ', ' order by i.id) from order_items i where i.order_id = o.id),
         o.total_paise, o.payment_status, o.fulfilment_status, o.courier, o.tracking_number, count(*) over()
  from orders o join customers c on c.id = o.customer_id
  where (q is null or o.order_number ilike '%' || q || '%' or c.full_name ilike '%' || q || '%' or c.email ilike '%' || q || '%'
         or coalesce(c.phone, '') ilike '%' || q || '%' or coalesce(o.shipping_address->>'phone', '') ilike '%' || q || '%'
         or coalesce(o.tracking_number, '') ilike '%' || q || '%'
         or exists (select 1 from order_items i where i.order_id = o.id and i.name_snapshot ilike '%' || q || '%'))
    and (p_payment is null or o.payment_status = p_payment)
    and (p_fulfilment is null or o.fulfilment_status = p_fulfilment)
    and (p_type is null or o.order_type = p_type)
    and (p_from is null or o.created_at >= p_from::timestamptz)
    and (p_to is null or o.created_at < (p_to + 1)::timestamptz)
  order by o.created_at desc
  limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0);
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_add_order_note(uuid,text)', 'admin_order_detail(uuid)',
    'admin_search_orders(text,payment_status,fulfilment_status,order_type,date,date,int,int)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
