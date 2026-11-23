create table couriers (
  name text primary key check (length(trim(name)) between 2 and 60),
  url_template text check (url_template is null or (url_template ~ '^https://[^ ]+$' and position('{tracking}' in url_template) > 0)),
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table couriers enable row level security;
revoke all on couriers from anon, authenticated;

create table order_update_log (
  id bigint generated always as identity primary key,
  order_id uuid not null references orders(id) on delete cascade,
  channel text not null check (channel in ('whatsapp', 'copy', 'email')),
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table order_update_log enable row level security;
revoke all on order_update_log from anon, authenticated;

create function admin_list_couriers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('orders.manage');
  return coalesce((select jsonb_agg(jsonb_build_object('name', name, 'url_template', url_template, 'is_active', is_active) order by name) from couriers), '[]'::jsonb);
end $$;

create function admin_save_courier(p_name text, p_url_template text, p_active boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old couriers;
begin
  perform _require('settings.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 or length(p_name) > 60 then raise exception 'invalid_input'; end if;
  if nullif(trim(coalesce(p_url_template, '')), '') is not null and (trim(p_url_template) !~ '^https://[^ ]+$' or position('{tracking}' in p_url_template) = 0) then raise exception 'invalid_template'; end if;
  select * into old from couriers where name = trim(p_name);
  insert into couriers (name, url_template, is_active) values (trim(p_name), nullif(trim(coalesce(p_url_template, '')), ''), coalesce(p_active, true))
    on conflict (name) do update set url_template = excluded.url_template, is_active = excluded.is_active, updated_at = now();
  perform _audit('courier.save', 'courier', trim(p_name), p_reason, to_jsonb(old), jsonb_build_object('url_template', p_url_template, 'active', p_active));
end $$;

-- Records that staff prepared a customer update. This is NOT a delivery receipt.
create function admin_log_order_update(p_order uuid, p_channel text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require('orders.manage');
  if not exists (select 1 from orders where id = p_order) then raise exception 'not_found'; end if;
  if p_channel not in ('whatsapp', 'copy', 'email') then raise exception 'invalid_input'; end if;
  insert into order_update_log (order_id, channel, created_by) values (p_order, p_channel, current_customer_id());
  perform _audit('order.update_prepared', 'order', p_order::text, 'Staff prepared a customer update (not a delivery receipt)', null, jsonb_build_object('channel', p_channel));
end $$;

create function admin_order_updates(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('orders.manage');
  return coalesce((select jsonb_agg(jsonb_build_object('channel', l.channel, 'at', l.created_at, 'by', c.full_name) order by l.created_at desc)
                   from order_update_log l left join customers c on c.id = l.created_by where l.order_id = p_order), '[]'::jsonb);
end $$;

revoke execute on function public.admin_list_couriers(), public.admin_save_courier(text, text, boolean, text), public.admin_log_order_update(uuid, text), public.admin_order_updates(uuid) from public, anon;
grant execute on function public.admin_list_couriers(), public.admin_save_courier(text, text, boolean, text), public.admin_log_order_update(uuid, text), public.admin_order_updates(uuid) to authenticated;
