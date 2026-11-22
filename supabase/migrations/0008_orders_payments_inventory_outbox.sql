-- Migration 0008: orders, payments, refunds, webhook events, inventory movements,
-- coupons, immutable status history, channel-agnostic notification outbox.
-- Money is integer paise. All writes happen server-side (service_role); RLS is read-only for clients.

create type order_type         as enum ('launch_preorder', 'regular_retail');
create type payment_status     as enum ('created', 'pending', 'captured', 'failed', 'refund_pending', 'refunded');
create type fulfilment_status  as enum ('unfulfilled', 'processing', 'packed', 'shipped', 'delivered', 'cancelled', 'returned');
create type outbox_status      as enum ('pending', 'sent', 'delivered', 'failed', 'cancelled');

create sequence order_number_seq start 1001;

create table orders (
  id                uuid primary key default gen_random_uuid(),
  order_number      text not null unique default ('MC-' || nextval('order_number_seq')::text),
  customer_id       uuid not null references customers(id),
  order_type        order_type not null,
  launch_id         uuid references launches(id),
  reservation_id    uuid references slot_reservations(id),
  subtotal_paise    int not null check (subtotal_paise >= 0),
  discount_paise    int not null default 0 check (discount_paise >= 0),
  shipping_paise    int not null default 0 check (shipping_paise >= 0),
  tax_paise         int not null default 0 check (tax_paise >= 0),   -- informational if prices are tax-inclusive
  total_paise       int not null check (total_paise >= 0),
  currency          text not null default 'INR',
  payment_status    payment_status not null default 'created',
  fulfilment_status fulfilment_status not null default 'unfulfilled',
  shipping_address  jsonb not null,
  coupon_code       text,
  courier           text,
  tracking_number   text,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check ((order_type = 'launch_preorder') = (launch_id is not null))
);
create index orders_customer_idx on orders (customer_id, created_at desc);
create index orders_status_idx on orders (payment_status, fulfilment_status);
create trigger orders_updated before update on orders
  for each row execute function set_updated_at();

create table order_items (
  id                  uuid primary key default gen_random_uuid(),
  order_id            uuid not null references orders(id) on delete cascade,
  variant_id          uuid references variants(id),
  bundle_id           uuid references bundles(id),
  name_snapshot       text not null,
  sku_snapshot        text not null,
  quantity            int not null check (quantity > 0),
  unit_price_paise    int not null check (unit_price_paise >= 0),
  line_total_paise    int not null check (line_total_paise >= 0),
  check ((variant_id is not null) <> (bundle_id is not null))
);
create index order_items_order_idx on order_items (order_id);

-- The slot tables were created before orders existed; link them now.
alter table launch_participations
  add constraint launch_participations_order_fk foreign key (order_id) references orders(id);
alter table slot_reservations
  add constraint slot_reservations_order_fk foreign key (order_id) references orders(id);

create table payments (
  id                    uuid primary key default gen_random_uuid(),
  order_id              uuid not null references orders(id),
  razorpay_order_id     text not null unique,
  razorpay_payment_id   text unique,
  amount_paise          int  not null check (amount_paise >= 0),
  status                payment_status not null default 'created',
  failure_reason        text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index payments_order_idx on payments (order_id);
create trigger payments_updated before update on payments
  for each row execute function set_updated_at();

create table refunds (
  id                  uuid primary key default gen_random_uuid(),
  payment_id          uuid not null references payments(id),
  razorpay_refund_id  text unique,
  amount_paise        int not null check (amount_paise > 0),
  reason              text not null,
  status              text not null default 'pending',
  created_at          timestamptz not null default now()
);

-- Webhook idempotency: the Razorpay event id is the primary key, so an event is never processed twice.
create table razorpay_events (
  event_id      text primary key,
  event_type    text not null,
  payload       jsonb not null,
  received_at   timestamptz not null default now(),
  processed_at  timestamptz
);

-- Payment status and fulfilment status are separate state machines; history is immutable.
create table order_status_history (
  id                 bigint generated always as identity primary key,
  order_id           uuid not null references orders(id) on delete cascade,
  kind               text not null check (kind in ('payment', 'fulfilment')),
  from_status        text,
  to_status          text not null,
  actor_customer_id  uuid references customers(id),
  note               text,
  created_at         timestamptz not null default now()
);
create index order_status_history_order_idx on order_status_history (order_id);
create trigger order_status_history_immutable before update or delete on order_status_history
  for each row execute function forbid_mutation();

-- Inventory movement history (append-only)
create table inventory_movements (
  id                 bigint generated always as identity primary key,
  variant_id         uuid not null references variants(id),
  movement           text not null check (movement in ('reserve', 'release', 'commit', 'adjust', 'restock', 'return')),
  quantity           int  not null,
  order_id           uuid references orders(id),
  reason             text,
  actor_customer_id  uuid references customers(id),
  created_at         timestamptz not null default now()
);
create index inventory_movements_variant_idx on inventory_movements (variant_id, created_at desc);
create trigger inventory_movements_immutable before update or delete on inventory_movements
  for each row execute function forbid_mutation();

-- Coupons (validated and applied server-side only; never readable by clients)
create table coupons (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique check (code = upper(code)),
  discount_type    text not null check (discount_type in ('percent', 'flat')),
  value            int  not null check (value > 0),          -- percent (1-100) or paise
  min_order_paise  int  not null default 0 check (min_order_paise >= 0),
  max_uses         int  check (max_uses is null or max_uses > 0),
  uses_count       int  not null default 0 check (uses_count >= 0),
  allow_on_launch  boolean not null default false,
  starts_at        timestamptz,
  ends_at          timestamptz,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  check (discount_type <> 'percent' or value <= 100)
);

-- Notification outbox: one table, channel-agnostic (whatsapp, email, staff_alert, later google_chat).
create table notification_outbox (
  id               uuid primary key default gen_random_uuid(),
  event_id         text not null unique,                     -- idempotency key
  channel          text not null,
  recipient        text,
  template         text not null,
  payload          jsonb not null default '{}',
  status           outbox_status not null default 'pending',
  attempts         int not null default 0,
  next_attempt_at  timestamptz not null default now(),
  last_error       text,
  created_at       timestamptz not null default now(),
  sent_at          timestamptz,
  delivered_at     timestamptz                               -- only set from a delivery receipt
);
create index outbox_due_idx on notification_outbox (next_attempt_at) where status = 'pending';

-- =====================================================================
-- Stock functions (row-locked, server-side only)
-- =====================================================================
create function reserve_stock(p_variant uuid, p_qty int, p_order uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare v variants%rowtype;
begin
  if p_qty <= 0 then return 'invalid_quantity'; end if;
  select * into v from variants where id = p_variant for update;
  if not found or not v.is_active then return 'not_found'; end if;
  if v.stock_on_hand - v.stock_reserved < p_qty then return 'insufficient'; end if;
  update variants set stock_reserved = stock_reserved + p_qty where id = p_variant;
  insert into inventory_movements (variant_id, movement, quantity, order_id)
  values (p_variant, 'reserve', p_qty, p_order);
  return 'reserved';
end $$;

create function release_stock(p_variant uuid, p_qty int, p_order uuid default null, p_reason text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v variants%rowtype;
begin
  select * into v from variants where id = p_variant for update;
  if not found then return 'not_found'; end if;
  if v.stock_reserved < p_qty then return 'insufficient_reserved'; end if;
  update variants set stock_reserved = stock_reserved - p_qty where id = p_variant;
  insert into inventory_movements (variant_id, movement, quantity, order_id, reason)
  values (p_variant, 'release', p_qty, p_order, p_reason);
  return 'released';
end $$;

-- Payment captured: reserved units leave the shelf.
create function commit_stock(p_variant uuid, p_qty int, p_order uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare v variants%rowtype;
begin
  select * into v from variants where id = p_variant for update;
  if not found then return 'not_found'; end if;
  if v.stock_reserved < p_qty then return 'insufficient_reserved'; end if;
  update variants
     set stock_reserved = stock_reserved - p_qty,
         stock_on_hand  = stock_on_hand  - p_qty
   where id = p_variant;
  insert into inventory_movements (variant_id, movement, quantity, order_id)
  values (p_variant, 'commit', p_qty, p_order);
  return 'committed';
end $$;

revoke execute on function reserve_stock(uuid, int, uuid)         from public, anon, authenticated;
revoke execute on function release_stock(uuid, int, uuid, text)   from public, anon, authenticated;
revoke execute on function commit_stock(uuid, int, uuid)          from public, anon, authenticated;
grant  execute on function reserve_stock(uuid, int, uuid)         to service_role;
grant  execute on function release_stock(uuid, int, uuid, text)   to service_role;
grant  execute on function commit_stock(uuid, int, uuid)          to service_role;

-- =====================================================================
-- Row Level Security: customers read their own; staff by permission; clients never write.
-- =====================================================================
alter table orders                enable row level security;
alter table order_items           enable row level security;
alter table payments              enable row level security;
alter table refunds               enable row level security;
alter table razorpay_events       enable row level security;
alter table order_status_history  enable row level security;
alter table inventory_movements   enable row level security;
alter table coupons               enable row level security;
alter table notification_outbox   enable row level security;

create policy orders_self_read  on orders for select using (customer_id = current_customer_id());
create policy orders_staff_read on orders for select using (has_permission('orders.view'));

create policy order_items_self_read on order_items for select using (
  exists (select 1 from orders o where o.id = order_id and o.customer_id = current_customer_id()));
create policy order_items_staff_read on order_items for select using (has_permission('orders.view'));

create policy payments_self_read on payments for select using (
  exists (select 1 from orders o where o.id = order_id and o.customer_id = current_customer_id()));
create policy payments_staff_read on payments for select using (has_permission('payments.view'));

create policy refunds_staff_read on refunds for select using (has_permission('payments.view'));

create policy status_history_self_read on order_status_history for select using (
  exists (select 1 from orders o where o.id = order_id and o.customer_id = current_customer_id()));
create policy status_history_staff_read on order_status_history for select using (has_permission('orders.view'));

create policy inventory_staff_read on inventory_movements for select using (has_permission('inventory.view'));

create policy coupons_staff_all on coupons for all
  using (has_permission('coupons.manage')) with check (has_permission('coupons.manage'));

create policy outbox_staff_read on notification_outbox for select using (has_permission('notifications.view'));

-- razorpay_events: RLS on, no policies = service_role only.

insert into role_permissions (role, permission) values
  ('admin',            'orders.view'),
  ('admin',            'payments.view'),
  ('admin',            'inventory.view'),
  ('admin',            'coupons.manage'),
  ('admin',            'notifications.view'),
  ('order_manager',    'orders.view'),
  ('order_manager',    'payments.view'),
  ('order_manager',    'inventory.view'),
  ('order_manager',    'notifications.view'),
  ('product_manager',  'inventory.view'),
  ('customer_support', 'orders.view'),
  ('customer_support', 'notifications.view');
