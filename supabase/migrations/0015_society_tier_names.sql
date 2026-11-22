-- Tier names confirmed in the master prompt (section 11).
update society_tiers set name = case tier
  when 1 then 'Origin Circle' when 2 then 'Collector Circle' when 3 then 'Connoisseur Circle'
  when 4 then 'Prestige Circle' when 5 then 'Grand Reserve' when 6 then 'Privé Circle' end;
select _audit('society.tier_names','society_tiers','1-6','Tier names set from the master prompt',null,'{"names":["Origin Circle","Collector Circle","Connoisseur Circle","Prestige Circle","Grand Reserve","Privé Circle"]}'::jsonb);
