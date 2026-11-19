-- =====================================================================
-- Milsen & Croft  |  Migration 0001
-- Foundation: identity, RBAC, audit log, catalogue, launches,
-- participations, slot reservations, allocation functions, RLS.
-- All writes to protected data go through server-side code using the
-- service_role key (never exposed to the browser) or the SECURITY
-- DEFINER functions below.
-- =====================================================================

-- ---------- Enums ----------
create type region_status      as enum ('draft', 'published', 'archived');
create type product_status     as enum ('concept', 'draft', 'approved', 'published', 'archived');
create type launch_status      as enum (
  'draft', 'pending_approval', 'preorder_active', 'paused', 'closed',
  'post_launch_review', 'published_in_shop', 'completed',
  'postponed', 'cancelled', 'archived'
);
create type staff_role         as enum (
  'super_admin', 'admin', 'product_manager',
  'order_manager', 'content_manager', 'customer_support'
);
create type reservation_status as enum ('active', 'converted', 'expired', 'released');

-- ---------- Shared helpers ----------
create function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create function forbid_mutation() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name;
end $$;

-- ---------- Identity ----------
-- Permanent internal customer ID, deliberately separate from the Google
-- email. email is NOT unique: accounts are never merged by email alone.
create table customers (
  id                       uuid primary key default gen_random_uuid(),
  auth_user_id             uuid unique references auth.users(id) on delete set null,
  email                    text,
  full_name                text,
  phone                    text,
  whatsapp_consent         boolean not null default false,
  whatsapp_consent_at      timestamptz,
  whatsapp_consent_source  text,
  is_active                boolean not null default true,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index customers_email_idx on customers (lower(email));
create trigger customers_updated before update on customers
  for each row execute function set_updated_at();

-- Every new Google sign-in becomes a plain customer. Admin access is
-- never granted here. The first Super Admin is bootstrapped by server
-- code reading SUPER_ADMIN_EMAIL (see docs).
create function handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into customers (auth_user_id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name')
  )
  on conflict (auth_user_id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_auth_user();

-- ---------- RBAC ----------
create table staff (
  customer_id  uuid primary key references customers(id) on delete cascade,
  role         staff_role not null,
  is_active    boolean not null default true,
  granted_by   uuid references customers(id),
  created_at   timestamptz not null default now()
);

create table role_permissions (
  role        staff_role not null,
  permission  text not null,
  primary key (role, permission)
);

create function current_customer_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from customers where auth_user_id = auth.uid() and is_active
$$;

-- super_admin always passes; other roles need an explicit grant.
create function has_permission(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from staff s
    where s.customer_id = current_customer_id()
      and s.is_active
      and (
        s.role = 'super_admin'
        or exists (
          select 1 from role_permissions rp
          where rp.role = s.role and rp.permission = p
        )
      )
  )
$$;

-- ---------- Audit log (append-only) ----------
create table audit_log (
  id                 bigint generated always as identity primary key,
  actor_customer_id  uuid references customers(id),
  action             text not null,
  entity_type        text not null,
  entity_id          text,
  reason             text,
  before_data        jsonb,
  after_data         jsonb,
  created_at         timestamptz not null default now()
);
create index audit_log_entity_idx on audit_log (entity_type, entity_id);
create trigger audit_log_immutable before update or delete on audit_log
  for each row execute function forbid_mutation();

-- ---------- Regions ----------
create table regions (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique check (code = upper(code) and code ~ '^[A-Z0-9-]{2,12}$'),
  name              text not null,
  country           text not null,
  description       text,
  story             text,
  cover_image_url   text,
  gallery           jsonb not null default '[]',
  seo_title         text,
  seo_description   text,
  status            region_status not null default 'draft',
  created_by        uuid references customers(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger regions_updated before update on regions
  for each row execute function set_updated_at();

-- ---------- Media ----------
create table media (
  id            uuid primary key default gen_random_uuid(),
  storage_path  text not null unique,
  kind          text not null default 'image',
  alt_text      text,
  uploaded_by   uuid references customers(id),
  created_at    timestamptz not null default now()
);

-- ---------- Products and variants ----------
-- Future concepts (Jwalan, Mullai, Goken, Hanafuyu) are stored with
-- status 'concept' and can never be purchased until approved.
create table products (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,            -- e.g. MC-KER-001
  name             text not null,
  region_id        uuid not null references regions(id),
  family           text not null,                   -- Fresh / Seductive Spicy / Local Floral
  story            text,
  notes            jsonb not null default '{}',     -- approved notes only
  images           jsonb not null default '[]',
  seo_title        text,
  seo_description  text,
  status           product_status not null default 'concept',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index products_region_idx on products (region_id);
create trigger products_updated before update on products
  for each row execute function set_updated_at();

create table variants (
  id                uuid primary key default gen_random_uuid(),
  product_id        uuid not null references products(id) on delete cascade,
  sku               text not null unique,
  size_ml           int  not null check (size_ml > 0),
  concentration     text,
  price_paise       int  not null check (price_paise >= 0),   -- money in paise, never floats
  compare_at_paise  int  check (compare_at_paise is null or compare_at_paise >= price_paise),
  stock_on_hand     int  not null default 0 check (stock_on_hand >= 0),
  stock_reserved    int  not null default 0 check (stock_reserved >= 0),
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (stock_reserved <= stock_on_hand)
);
create trigger variants_updated before update on variants
  for each row execute function set_updated_at();

-- ---------- Launches ----------
create table launches (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,            -- e.g. KJ
  name             text not null,
  region_id        uuid not null references regions(id),
  story            text,
  banner_urls      jsonb not null default '[]',
  status           launch_status not null default 'draft',
  capacity         int not null default 100 check (capacity > 0),
  allocated_count  int not null default 0 check (allocated_count >= 0),
  society_eligible boolean not null default true,
  closed_at        timestamptz,
  closed_reason    text,
  created_by       uuid references customers(id),
  approved_by      uuid references customers(id),
  published_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (allocated_count <= capacity)
);
create trigger launches_updated before update on launches
  for each row execute function set_updated_at();

create table launch_products (
  launch_id   uuid not null references launches(id) on delete cascade,
  product_id  uuid not null references products(id),
  primary key (launch_id, product_id)
);

create table launch_variants (
  launch_id             uuid not null references launches(id) on delete cascade,
  variant_id            uuid not null references variants(id),
  launch_price_paise    int check (launch_price_paise is null or launch_price_paise >= 0),
  is_available          boolean not null default true,
  primary key (launch_id, variant_id)
);

-- ---------- Participation: one slot per customer per launch ----------
-- order_id gets its foreign key in the orders migration.
create table launch_participations (
  id           uuid primary key default gen_random_uuid(),
  launch_id    uuid not null references launches(id),
  customer_id  uuid not null references customers(id),
  order_id     uuid,
  created_at   timestamptz not null default now(),
  constraint one_slot_per_customer_per_launch unique (launch_id, customer_id)
);

-- ---------- Slot reservations (temporary holds before payment) ----------
create table slot_reservations (
  id           uuid primary key default gen_random_uuid(),
  launch_id    uuid not null references launches(id),
  customer_id  uuid not null references customers(id),
  status       reservation_status not null default 'active',
  expires_at   timestamptz not null,
  order_id     uuid,
  created_at   timestamptz not null default now()
);
create unique index one_active_reservation_per_customer
  on slot_reservations (launch_id, customer_id) where status = 'active';
create index slot_reservations_expiry_idx
  on slot_reservations (expires_at) where status = 'active';

-- =====================================================================
-- Allocation functions. Every one takes a row lock on the launch so
-- simultaneous requests are serialised and can never over-allocate.
-- =====================================================================

-- 1) Hold a slot BEFORE any payment is attempted.
create function reserve_launch_slot(
  p_launch uuid, p_customer uuid, p_ttl_minutes int default 15
) returns table (r_result text, r_reservation_id uuid, r_expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  l        launches%rowtype;
  v_active int;
  v_res    slot_reservations%rowtype;
begin
  select * into l from launches where id = p_launch for update;
  if not found then
    return query select 'not_found'::text, null::uuid, null::timestamptz; return;
  end if;
  if l.status <> 'preorder_active' then
    return query select 'closed'::text, null::uuid, null::timestamptz; return;
  end if;
  if exists (select 1 from launch_participations lp
             where lp.launch_id = p_launch and lp.customer_id = p_customer) then
    return query select 'existing'::text, null::uuid, null::timestamptz; return;
  end if;

  -- sweep stale holds so their slots return to the pool
  update slot_reservations sr set status = 'expired'
   where sr.launch_id = p_launch and sr.status = 'active' and sr.expires_at <= now();

  -- reuse this customer's live hold
  select * into v_res from slot_reservations sr
   where sr.launch_id = p_launch and sr.customer_id = p_customer and sr.status = 'active';
  if found then
    return query select 'reserved'::text, v_res.id, v_res.expires_at; return;
  end if;

  select count(*) into v_active from slot_reservations sr
   where sr.launch_id = p_launch and sr.status = 'active';
  if l.allocated_count + v_active >= l.capacity then
    return query select 'full'::text, null::uuid, null::timestamptz; return;
  end if;

  insert into slot_reservations (launch_id, customer_id, expires_at)
  values (p_launch, p_customer, now() + make_interval(mins => p_ttl_minutes))
  returning * into v_res;

  return query select 'reserved'::text, v_res.id, v_res.expires_at;
end $$;

-- 2) Convert a hold into a permanent slot. Call ONLY from the verified
--    Razorpay webhook handler, after signature and amount checks.
--    Returns: allocated | existing | full | launch_unavailable | not_found.
--    'full' or 'launch_unavailable' after a captured payment means the
--    caller must trigger the automatic Razorpay refund fallback.
create function confirm_launch_slot(
  p_launch uuid, p_customer uuid, p_order uuid default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  l        launches%rowtype;
  v_res    slot_reservations%rowtype;
  v_others int;
  v_closing boolean;
  v_has_res boolean;
begin
  select * into l from launches where id = p_launch for update;
  if not found then return 'not_found'; end if;

  if exists (select 1 from launch_participations lp
             where lp.launch_id = p_launch and lp.customer_id = p_customer) then
    return 'existing';                         -- idempotent: webhook retries are safe
  end if;

  if l.status <> 'preorder_active' then return 'launch_unavailable'; end if;
  if l.allocated_count >= l.capacity then return 'full'; end if;

  select * into v_res from slot_reservations sr
   where sr.launch_id = p_launch and sr.customer_id = p_customer and sr.status = 'active'
   order by sr.created_at desc limit 1;
  v_has_res := found;

  if not v_has_res then
    -- hold was swept (late payment): only allocate if a slot is genuinely free
    select count(*) into v_others from slot_reservations sr
     where sr.launch_id = p_launch and sr.status = 'active' and sr.expires_at > now();
    if l.allocated_count + v_others >= l.capacity then return 'full'; end if;
  end if;

  insert into launch_participations (launch_id, customer_id, order_id)
  values (p_launch, p_customer, p_order);

  if v_has_res then
    update slot_reservations set status = 'converted', order_id = p_order where id = v_res.id;
  end if;

  v_closing := (l.allocated_count + 1 >= l.capacity);
  update launches
     set allocated_count = allocated_count + 1,
         status          = case when v_closing then 'closed'::launch_status else status end,
         closed_at       = case when v_closing then now() else closed_at end,
         closed_reason   = case when v_closing then 'fully_allocated' else closed_reason end
   where id = p_launch;

  return 'allocated';
end $$;

-- 3) Scheduled sweep (run every minute with pg_cron or a server job).
create function release_expired_reservations() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update slot_reservations set status = 'expired'
   where status = 'active' and expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Browser roles must never call these directly.
revoke execute on function reserve_launch_slot(uuid, uuid, int)  from public, anon, authenticated;
revoke execute on function confirm_launch_slot(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function release_expired_reservations()        from public, anon, authenticated;
grant  execute on function reserve_launch_slot(uuid, uuid, int)  to service_role;
grant  execute on function confirm_launch_slot(uuid, uuid, uuid) to service_role;
grant  execute on function release_expired_reservations()        to service_role;

-- =====================================================================
-- Row Level Security
-- Default deny. Customers read only their own rows; public sees only
-- published content; staff access is permission-based. Writes to
-- protected data happen server-side with the service_role key.
-- =====================================================================
alter table customers             enable row level security;
alter table staff                 enable row level security;
alter table role_permissions      enable row level security;
alter table audit_log             enable row level security;
alter table regions               enable row level security;
alter table media                 enable row level security;
alter table products              enable row level security;
alter table variants              enable row level security;
alter table launches              enable row level security;
alter table launch_products       enable row level security;
alter table launch_variants       enable row level security;
alter table launch_participations enable row level security;
alter table slot_reservations     enable row level security;

-- Customers: own row only (no client-side updates of protected fields)
create policy customers_self_read   on customers for select using (id = current_customer_id());
create policy customers_staff_read  on customers for select using (has_permission('customers.view'));

-- Staff and permissions: Super Admin / staff managers only
create policy staff_manage on staff for all
  using (has_permission('staff.manage')) with check (has_permission('staff.manage'));
create policy staff_self_read on staff for select using (customer_id = current_customer_id());
create policy role_permissions_manage on role_permissions for all
  using (has_permission('staff.manage')) with check (has_permission('staff.manage'));

-- Audit log: readable by authorised staff, never writable from the client
create policy audit_staff_read on audit_log for select using (has_permission('audit.view'));

-- Public catalogue: published content only, drafts and concepts never exposed
create policy regions_public_read on regions for select using (status = 'published');
create policy regions_staff_all   on regions for all
  using (has_permission('catalog.manage')) with check (has_permission('catalog.manage'));

create policy products_public_read on products for select using (status = 'published');
create policy products_staff_all   on products for all
  using (has_permission('catalog.manage')) with check (has_permission('catalog.manage'));

create policy variants_public_read on variants for select using (
  is_active and exists (select 1 from products p where p.id = product_id and p.status = 'published')
);
create policy variants_staff_all on variants for all
  using (has_permission('catalog.manage')) with check (has_permission('catalog.manage'));

create policy media_staff_all on media for all
  using (has_permission('media.manage')) with check (has_permission('media.manage'));

-- Launches: public sees only launches that are live or finished
create policy launches_public_read on launches for select using (
  status in ('preorder_active', 'closed', 'post_launch_review', 'published_in_shop', 'completed')
);
create policy launches_staff_read on launches for select using (has_permission('launches.view'));
create policy launches_staff_write on launches for all
  using (has_permission('launches.manage')) with check (has_permission('launches.manage'));

create policy launch_products_public_read on launch_products for select using (
  exists (select 1 from launches l where l.id = launch_id
          and l.status in ('preorder_active', 'closed', 'post_launch_review', 'published_in_shop', 'completed'))
);
create policy launch_products_staff_all on launch_products for all
  using (has_permission('launches.manage')) with check (has_permission('launches.manage'));

create policy launch_variants_public_read on launch_variants for select using (
  exists (select 1 from launches l where l.id = launch_id
          and l.status in ('preorder_active', 'closed', 'post_launch_review', 'published_in_shop', 'completed'))
);
create policy launch_variants_staff_all on launch_variants for all
  using (has_permission('launches.manage')) with check (has_permission('launches.manage'));

-- Participations and reservations: own rows readable, nothing writable by clients
create policy participations_self_read  on launch_participations for select using (customer_id = current_customer_id());
create policy participations_staff_read on launch_participations for select using (has_permission('launches.view'));
create policy reservations_self_read    on slot_reservations     for select using (customer_id = current_customer_id());
create policy reservations_staff_read   on slot_reservations     for select using (has_permission('launches.view'));

-- ---------- Starter permission grants (adjust in admin later) ----------
insert into role_permissions (role, permission) values
  ('admin',            'customers.view'),
  ('admin',            'catalog.manage'),
  ('admin',            'media.manage'),
  ('admin',            'launches.view'),
  ('admin',            'audit.view'),
  ('product_manager',  'catalog.manage'),
  ('product_manager',  'media.manage'),
  ('product_manager',  'launches.view'),
  ('product_manager',  'launches.manage'),
  ('content_manager',  'media.manage'),
  ('order_manager',    'customers.view'),
  ('order_manager',    'launches.view'),
  ('customer_support', 'customers.view');
