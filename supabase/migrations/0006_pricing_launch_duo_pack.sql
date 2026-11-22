-- Migration 0006: 50 ml variants, Kerala x Japan launch (multi-region), duo-pack bundle.
-- All money in paise. Everything seeded as DRAFT: nothing public until published in admin.

-- 1) A launch can span several regions (Kerala x Japan)
alter table launches alter column region_id drop not null;

create table launch_regions (
  launch_id  uuid not null references launches(id) on delete cascade,
  region_id  uuid not null references regions(id),
  primary key (launch_id, region_id)
);
alter table launch_regions enable row level security;
create policy launch_regions_public_read on launch_regions for select using (
  exists (select 1 from launches l where l.id = launch_id
          and l.status in ('preorder_active', 'closed', 'post_launch_review', 'published_in_shop', 'completed'))
);
create policy launch_regions_staff_all on launch_regions for all
  using (has_permission('launches.manage')) with check (has_permission('launches.manage'));

-- 2) Bundles (duo pack): a priced set of variants sold together
create table bundles (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  description text,
  price_paise int  not null check (price_paise >= 0),
  status      product_status not null default 'draft',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger bundles_updated before update on bundles
  for each row execute function set_updated_at();

create table bundle_items (
  bundle_id   uuid not null references bundles(id) on delete cascade,
  variant_id  uuid not null references variants(id),
  quantity    int  not null default 1 check (quantity > 0),
  primary key (bundle_id, variant_id)
);

alter table bundles      enable row level security;
alter table bundle_items enable row level security;
create policy bundles_public_read on bundles for select using (status = 'published');
create policy bundles_staff_all   on bundles for all
  using (has_permission('catalog.manage')) with check (has_permission('catalog.manage'));
create policy bundle_items_public_read on bundle_items for select using (
  exists (select 1 from bundles b where b.id = bundle_id and b.status = 'published')
);
create policy bundle_items_staff_all on bundle_items for all
  using (has_permission('catalog.manage')) with check (has_permission('catalog.manage'));

-- 3) 50 ml variants: 500 units each, regular price Rs 1,499
insert into variants (product_id, sku, size_ml, price_paise, stock_on_hand)
select p.id, p.code || '-50ML', 50, 149900, 500
from products p where p.code in ('MC-KER-001', 'MC-JAP-001')
on conflict (sku) do nothing;

-- 4) Kerala x Japan launch: 100 combined slots, pre-order price Rs 999 per bottle
insert into launches (code, name, status, capacity)
values ('KJ', 'Kerala x Japan', 'draft', 100)
on conflict (code) do nothing;

insert into launch_regions (launch_id, region_id)
select l.id, r.id from launches l, regions r
where l.code = 'KJ' and r.code in ('KER', 'JAP')
on conflict do nothing;

insert into launch_products (launch_id, product_id)
select l.id, p.id from launches l, products p
where l.code = 'KJ' and p.code in ('MC-KER-001', 'MC-JAP-001')
on conflict do nothing;

insert into launch_variants (launch_id, variant_id, launch_price_paise)
select l.id, v.id, 99900 from launches l, variants v
where l.code = 'KJ' and v.sku in ('MC-KER-001-50ML', 'MC-JAP-001-50ML')
on conflict do nothing;

-- 5) Duo pack: 1 Kerala + 1 Japan for Rs 1,999
insert into bundles (code, name, price_paise)
values ('MC-DUO-001', 'Kerala x Japan Duo', 199900)
on conflict (code) do nothing;

insert into bundle_items (bundle_id, variant_id, quantity)
select b.id, v.id, 1 from bundles b, variants v
where b.code = 'MC-DUO-001' and v.sku in ('MC-KER-001-50ML', 'MC-JAP-001-50ML')
on conflict do nothing;
