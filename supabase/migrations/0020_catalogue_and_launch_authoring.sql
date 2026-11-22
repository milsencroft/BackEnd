-- Content authoring for regions, products and launch drafts. Publication stays with the existing status functions
-- (Super Admin controls publication); every change needs a reason and is audited.
create function admin_catalogue() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('catalog.manage');
  return jsonb_build_object(
    'regions', coalesce((select jsonb_agg(to_jsonb(r) - 'gallery' - 'created_by' order by r.name) from regions r), '[]'),
    'products', coalesce((select jsonb_agg(to_jsonb(p) - 'images' || jsonb_build_object('region_code', (select code from regions where id = p.region_id),
        'variants', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'sku', v.sku, 'size_ml', v.size_ml, 'price_paise', v.price_paise, 'is_active', v.is_active) order by v.size_ml) from variants v where v.product_id = p.id), '[]')) order by p.code) from products p), '[]'));
end $$;

create function admin_save_region(p_code text, p_name text, p_country text, p_description text, p_story text,
  p_cover_image_url text, p_seo_title text, p_seo_description text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old regions%rowtype; found_old boolean;
begin
  perform _require('catalog.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_code !~ '^[A-Z]{2,6}$' then raise exception 'invalid_code'; end if;
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_country), '') = '' then raise exception 'invalid_input'; end if;
  if p_cover_image_url is not null and p_cover_image_url !~ '^https://' then raise exception 'invalid_input'; end if;
  select * into old from regions where code = p_code; found_old := found;
  if found_old then
    update regions set name = trim(p_name), country = trim(p_country), description = p_description, story = p_story,
      cover_image_url = p_cover_image_url, seo_title = p_seo_title, seo_description = p_seo_description, updated_at = now() where code = p_code;
  else
    insert into regions (code, name, country, description, story, cover_image_url, seo_title, seo_description, status, created_by)
    values (p_code, trim(p_name), trim(p_country), p_description, p_story, p_cover_image_url, p_seo_title, p_seo_description, 'draft', current_customer_id());
  end if;
  perform _audit(case when found_old then 'region.update' else 'region.create' end, 'region', p_code, p_reason,
    case when found_old then to_jsonb(old) - 'gallery' end, jsonb_build_object('name', p_name, 'country', p_country));
end $$;

create function admin_save_product(p_code text, p_name text, p_region_code text, p_family text, p_story text, p_notes jsonb,
  p_seo_title text, p_seo_description text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old products%rowtype; found_old boolean; rid uuid;
begin
  perform _require('catalog.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_code !~ '^MC-[A-Z]{3}-[0-9]{3}$' then raise exception 'invalid_code'; end if;
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_family), '') = '' then raise exception 'invalid_input'; end if;
  if p_notes is not null and (jsonb_typeof(p_notes) <> 'array' or jsonb_array_length(p_notes) > 15) then raise exception 'invalid_input'; end if;
  select id into rid from regions where code = p_region_code;
  if rid is null then raise exception 'region_not_found'; end if;
  select * into old from products where code = p_code; found_old := found;
  if found_old then
    update products set name = trim(p_name), region_id = rid, family = trim(p_family), story = p_story, notes = coalesce(p_notes, notes),
      seo_title = p_seo_title, seo_description = p_seo_description, updated_at = now() where code = p_code;
  else
    insert into products (code, name, region_id, family, story, notes, seo_title, seo_description, status)
    values (p_code, trim(p_name), rid, trim(p_family), p_story, coalesce(p_notes, '[]'::jsonb), p_seo_title, p_seo_description, 'draft');
  end if;
  perform _audit(case when found_old then 'product.update' else 'product.create' end, 'product', p_code, p_reason,
    case when found_old then to_jsonb(old) - 'images' end, jsonb_build_object('name', p_name, 'region', p_region_code, 'family', p_family));
end $$;

create function admin_create_launch(p_code text, p_name text, p_region_codes text[], p_story text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare lid uuid; rid uuid; c text; first_rid uuid;
begin
  perform _require('launches.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_code !~ '^[A-Z]{2,6}$' or coalesce(trim(p_name), '') = '' or coalesce(array_length(p_region_codes, 1), 0) = 0 then raise exception 'invalid_input'; end if;
  if exists (select 1 from launches where code = p_code) then raise exception 'duplicate_code'; end if;
  foreach c in array p_region_codes loop
    select id into rid from regions where code = c;
    if rid is null then raise exception 'region_not_found'; end if;
    first_rid := coalesce(first_rid, rid);
  end loop;
  -- capacity defaults to 100 (table default); only a Super Admin may change it later, with a reason.
  insert into launches (code, name, region_id, story, status, created_by) values (p_code, trim(p_name), first_rid, p_story, 'draft', current_customer_id()) returning id into lid;
  foreach c in array p_region_codes loop
    insert into launch_regions (launch_id, region_id) select lid, id from regions where code = c on conflict do nothing;
  end loop;
  perform _audit('launch.create', 'launch', p_code, p_reason, null, jsonb_build_object('name', p_name, 'regions', p_region_codes));
end $$;

create function admin_set_launch_variants(p_code text, p_items jsonb, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare l launches%rowtype; it jsonb; v variants%rowtype;
begin
  perform _require('launches.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into l from launches where code = p_code for update;
  if not found then raise exception 'not_found'; end if;
  if l.status not in ('draft', 'pending_approval') then raise exception 'launch_locked'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'invalid_input'; end if;
  delete from launch_variants where launch_id = l.id;
  delete from launch_products where launch_id = l.id;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into v from variants where sku = it->>'sku';
    if not found then raise exception 'sku_not_found'; end if;
    if (it->>'launch_price_paise')::int is null or (it->>'launch_price_paise')::int <= 0 then raise exception 'invalid_price'; end if;
    insert into launch_products (launch_id, product_id) values (l.id, v.product_id) on conflict do nothing;
    insert into launch_variants (launch_id, variant_id, launch_price_paise, is_available) values (l.id, v.id, (it->>'launch_price_paise')::int, true);
  end loop;
  perform _audit('launch.variants', 'launch', p_code, p_reason, null, p_items);
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_catalogue()', 'admin_save_region(text,text,text,text,text,text,text,text,text)',
    'admin_save_product(text,text,text,text,text,jsonb,text,text,text)', 'admin_create_launch(text,text,text[],text,text)', 'admin_set_launch_variants(text,jsonb,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
