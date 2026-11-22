-- Future concepts: unapproved working names, status 'concept' (never public, never purchasable).
-- Family left as 'Unassigned' until the owner decides.
insert into products (code, name, region_id, family, status)
select v.code, v.name, r.id, 'Unassigned', 'concept'
from (values
  ('MC-KER-002', 'Jwalan',   'KER'),
  ('MC-KER-003', 'Mullai',   'KER'),
  ('MC-JAP-002', 'Goken',    'JAP'),
  ('MC-JAP-003', 'Hanafuyu', 'JAP')
) as v(code, name, region_code)
join regions r on r.code = v.region_code
on conflict (code) do nothing;
