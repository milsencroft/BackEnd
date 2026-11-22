-- Seed the two launch regions and two launch products as DRAFT (not public, not purchasable).
insert into regions (code, name, country, status) values
  ('KER', 'Kerala', 'India', 'draft'),
  ('JAP', 'Japan',  'Japan', 'draft')
on conflict (code) do nothing;

insert into products (code, name, region_id, family, status)
select 'MC-KER-001', 'Mazha Fresh', r.id, 'Fresh', 'draft' from regions r where r.code = 'KER'
on conflict (code) do nothing;

insert into products (code, name, region_id, family, status)
select 'MC-JAP-001', 'Seiran Fresh', r.id, 'Fresh', 'draft' from regions r where r.code = 'JAP'
on conflict (code) do nothing;
