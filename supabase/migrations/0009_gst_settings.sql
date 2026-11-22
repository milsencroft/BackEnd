-- Migration 0009: GST toggle and calculation (Indian GST: CGST+SGST within the seller's state, IGST across states).
-- Default is OFF so nothing changes until the Super Admin switches it on after confirming with a CA.

create table store_settings (
  key         text primary key,
  value       jsonb not null,
  updated_by  uuid references customers(id),
  updated_at  timestamptz not null default now()
);
create trigger store_settings_updated before update on store_settings
  for each row execute function set_updated_at();

-- enabled:        master switch
-- mode:           'inclusive' = listed prices already contain GST (tax is extracted from the price)
--                 'exclusive' = GST is added on top at checkout
-- default_rate_bps: 1800 = 18 % (perfumes, HSN 3303). Per-product override: products.gst_rate_bps
-- seller_state_code: GST state code of the seller (Kerala = 32). Same state = CGST+SGST, else IGST.
insert into store_settings (key, value) values
  ('gst', '{"enabled": false, "mode": "inclusive", "default_rate_bps": 1800, "seller_state_code": "32", "gstin": null}');

alter table products add column hsn_code text not null default '3303';
alter table products add column gst_rate_bps int check (gst_rate_bps is null or gst_rate_bps between 0 and 10000);

alter table orders
  add column gst_mode        text,
  add column gst_rate_bps    int,
  add column ship_state_code text,
  add column cgst_paise      int not null default 0 check (cgst_paise >= 0),
  add column sgst_paise      int not null default 0 check (sgst_paise >= 0),
  add column igst_paise      int not null default 0 check (igst_paise >= 0);

-- Single source of truth for tax maths. Pass the taxable amount (items after discount, plus shipping).
-- amount_to_add_paise is what gets ADDED to the total: 0 when inclusive, the tax when exclusive.
create function calc_gst(p_amount_paise int, p_ship_state_code text, p_rate_bps int default null)
returns table (r_mode text, r_rate_bps int, r_tax_paise int, r_cgst_paise int,
               r_sgst_paise int, r_igst_paise int, r_amount_to_add_paise int)
language plpgsql stable security definer set search_path = public as $$
declare
  s        jsonb;
  v_rate   int;
  v_tax    int;
  v_cgst   int := 0;
  v_sgst   int := 0;
  v_igst   int := 0;
  v_mode   text;
begin
  select value into s from store_settings where key = 'gst';
  if s is null or not coalesce((s->>'enabled')::boolean, false) or p_amount_paise <= 0 then
    return query select 'off'::text, 0, 0, 0, 0, 0, 0; return;
  end if;

  v_mode := s->>'mode';
  v_rate := coalesce(p_rate_bps, (s->>'default_rate_bps')::int);

  if v_mode = 'inclusive' then
    v_tax := p_amount_paise - round(p_amount_paise::numeric * 10000 / (10000 + v_rate))::int;
  else
    v_tax := round(p_amount_paise::numeric * v_rate / 10000)::int;
  end if;

  if p_ship_state_code is not distinct from (s->>'seller_state_code') then
    v_cgst := v_tax / 2;
    v_sgst := v_tax - v_cgst;
  else
    v_igst := v_tax;
  end if;

  return query select v_mode, v_rate, v_tax, v_cgst, v_sgst, v_igst,
                      case when v_mode = 'exclusive' then v_tax else 0 end;
end $$;

revoke execute on function calc_gst(int, text, int) from public, anon, authenticated;
grant  execute on function calc_gst(int, text, int) to service_role;

-- Every settings change is auditable.
create function audit_store_settings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (actor_customer_id, action, entity_type, entity_id, reason, before_data, after_data)
  values (current_customer_id(), 'store_settings.update', 'store_settings', new.key,
          'store_settings changed', to_jsonb(old.value), to_jsonb(new.value));
  return new;
end $$;
revoke execute on function audit_store_settings() from public, anon, authenticated;
create trigger store_settings_audit after update on store_settings
  for each row execute function audit_store_settings();

-- RLS: staff can read; only Super Admin can change ('settings.manage' is granted to no role).
alter table store_settings enable row level security;
create policy settings_staff_read on store_settings for select using (has_permission('settings.view'));
create policy settings_manage on store_settings for update
  using (has_permission('settings.manage')) with check (has_permission('settings.manage'));

insert into role_permissions (role, permission) values ('admin', 'settings.view');
