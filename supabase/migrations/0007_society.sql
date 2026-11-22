-- Migration 0007: Society tiers, memberships, history, waiting list, missed launches.
create type membership_status as enum ('active', 'lapsed', 'cancelled');

create table society_tiers (
  tier        int primary key check (tier between 1 and 6),
  name        text not null,
  cap         int not null default 100 check (cap > 0),
  updated_at  timestamptz not null default now()
);
create trigger society_tiers_updated before update on society_tiers
  for each row execute function set_updated_at();

-- Only Tier 1 and Tier 6 names are confirmed; rename tiers 2-5 in admin (Super Admin only).
insert into society_tiers (tier, name) values
  (1, 'Origin Circle'), (2, 'Tier 2'), (3, 'Tier 3'),
  (4, 'Tier 4'),        (5, 'Tier 5'), (6, 'Privé Circle');

create table society_memberships (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid not null references customers(id),
  tier               int  not null references society_tiers(tier),
  launch_id          uuid not null references launches(id),
  membership_number  text not null unique,   -- MS-[LAUNCH CODE]-T[TIER]-[NUMBER]
  status             membership_status not null default 'active',
  joined_at          timestamptz not null default now(),
  ended_at           timestamptz
);
-- One active membership per customer
create unique index one_active_membership_per_customer
  on society_memberships (customer_id) where status = 'active';
create index society_memberships_tier_idx on society_memberships (tier) where status = 'active';

create table society_membership_history (
  id           bigint generated always as identity primary key,
  membership_id uuid references society_memberships(id),
  customer_id  uuid not null references customers(id),
  from_tier    int,
  to_tier      int,
  reason       text not null,
  actor_customer_id uuid references customers(id),
  created_at   timestamptz not null default now()
);
create trigger society_history_immutable before update or delete on society_membership_history
  for each row execute function forbid_mutation();

-- Tier queues / Tier 1 re-entry list
create table society_waiting_list (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references customers(id),
  tier         int  not null references society_tiers(tier),
  created_at   timestamptz not null default now(),
  unique (customer_id, tier)
);

-- Launches a member did not take part in. Cancelled/postponed launches are never recorded here.
create table missed_launches (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references customers(id),
  launch_id    uuid not null references launches(id),
  created_at   timestamptz not null default now(),
  unique (customer_id, launch_id)
);

-- Grant a membership after a confirmed launch slot. Serialised per tier by a row lock,
-- so a tier can never exceed its cap. Server-side only.
create function grant_membership(p_customer uuid, p_launch uuid, p_tier int default 1)
returns table (r_result text, r_membership_id uuid, r_number text)
language plpgsql security definer set search_path = public as $$
declare
  t        society_tiers%rowtype;
  l        launches%rowtype;
  v_id     uuid;
  v_num    text;
  v_active int;
  v_seq    int;
begin
  select * into t from society_tiers where tier = p_tier for update;
  if not found then
    return query select 'invalid_tier'::text, null::uuid, null::text; return;
  end if;
  select * into l from launches where id = p_launch;
  if not found then
    return query select 'not_found'::text, null::uuid, null::text; return;
  end if;

  select m.id, m.membership_number into v_id, v_num
    from society_memberships m where m.customer_id = p_customer and m.status = 'active';
  if found then
    return query select 'existing'::text, v_id, v_num; return;
  end if;

  select count(*) into v_active from society_memberships m where m.tier = p_tier and m.status = 'active';
  if v_active >= t.cap then
    insert into society_waiting_list (customer_id, tier) values (p_customer, p_tier)
      on conflict do nothing;
    return query select 'waitlisted'::text, null::uuid, null::text; return;
  end if;

  select count(*) + 1 into v_seq from society_memberships m
   where m.launch_id = p_launch and m.tier = p_tier;
  v_num := 'MS-' || l.code || '-T' || p_tier || '-' || lpad(v_seq::text, 3, '0');

  insert into society_memberships (customer_id, tier, launch_id, membership_number)
  values (p_customer, p_tier, p_launch, v_num) returning id into v_id;

  insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason)
  values (v_id, p_customer, null, p_tier, 'Joined via launch ' || l.code);

  delete from society_waiting_list where customer_id = p_customer and tier = p_tier;

  return query select 'granted'::text, v_id, v_num;
end $$;

revoke execute on function grant_membership(uuid, uuid, int) from public, anon, authenticated;
grant  execute on function grant_membership(uuid, uuid, int) to service_role;

-- RLS
alter table society_tiers              enable row level security;
alter table society_memberships        enable row level security;
alter table society_membership_history enable row level security;
alter table society_waiting_list       enable row level security;
alter table missed_launches            enable row level security;

-- Tier names/caps are not sensitive. Caps editable by Super Admin only
-- ('society.manage' is deliberately granted to no role, so only super_admin passes).
create policy tiers_read on society_tiers for select using (true);
create policy tiers_manage on society_tiers for update
  using (has_permission('society.manage')) with check (has_permission('society.manage'));

create policy memberships_self_read  on society_memberships for select using (customer_id = current_customer_id());
create policy memberships_staff_read on society_memberships for select using (has_permission('society.view'));
create policy history_self_read      on society_membership_history for select using (customer_id = current_customer_id());
create policy history_staff_read     on society_membership_history for select using (has_permission('society.view'));
create policy waiting_self_read      on society_waiting_list for select using (customer_id = current_customer_id());
create policy waiting_staff_read     on society_waiting_list for select using (has_permission('society.view'));
create policy missed_self_read       on missed_launches for select using (customer_id = current_customer_id());
create policy missed_staff_read      on missed_launches for select using (has_permission('society.view'));

insert into role_permissions (role, permission) values
  ('admin', 'society.view'),
  ('customer_support', 'society.view');
