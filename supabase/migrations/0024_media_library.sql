create table media_assets (
  id uuid primary key default gen_random_uuid(),
  path text not null unique,
  alt_text text not null check (length(trim(alt_text)) between 3 and 200),
  uploaded_by uuid,
  created_at timestamptz not null default now()
);
alter table media_assets enable row level security;
revoke all on media_assets from anon, authenticated;

create function admin_register_media(p_path text, p_alt text, p_reason text) returns uuid
language plpgsql security definer set search_path = public, storage as $$
declare rid uuid;
begin
  perform _require('media.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if length(trim(coalesce(p_alt, ''))) < 3 or length(p_alt) > 200 then raise exception 'alt_required'; end if;
  if p_path !~ '^products/[a-f0-9-]{36}\.(jpg|jpeg|png|webp|avif)$' then raise exception 'invalid_path'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'product-media' and name = p_path) then raise exception 'file_missing'; end if;
  insert into media_assets (path, alt_text, uploaded_by) values (p_path, trim(p_alt), current_customer_id()) returning id into rid;
  perform _audit('media.register', 'media', rid::text, p_reason, null, jsonb_build_object('path', p_path, 'alt', trim(p_alt)));
  return rid;
end $$;

create function admin_update_media_alt(p_id uuid, p_alt text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare a media_assets;
begin
  perform _require('media.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if length(trim(coalesce(p_alt, ''))) < 3 or length(p_alt) > 200 then raise exception 'alt_required'; end if;
  select * into a from media_assets where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  update media_assets set alt_text = trim(p_alt) where id = p_id;
  update products set images = (select coalesce(jsonb_agg(case when e->>'path' = a.path then jsonb_set(e, '{alt}', to_jsonb(trim(p_alt))) else e end), '[]'::jsonb)
                                  from jsonb_array_elements(images) e)
   where jsonb_typeof(images) = 'array' and images @> jsonb_build_array(jsonb_build_object('path', a.path));
  perform _audit('media.alt', 'media', p_id::text, p_reason, to_jsonb(a.alt_text), to_jsonb(trim(p_alt)));
end $$;

create function admin_set_product_images(p_code text, p_paths text[], p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare imgs jsonb; old jsonb;
begin
  perform _require('catalog.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if coalesce(array_length(p_paths, 1), 0) > 8 then raise exception 'too_many'; end if;
  select images into old from products where code = p_code for update;
  if not found then raise exception 'not_found'; end if;
  if exists (select 1 from unnest(coalesce(p_paths, '{}')) x where not exists (select 1 from media_assets m where m.path = x)) then raise exception 'unknown_media'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('path', m.path, 'alt', m.alt_text) order by u.ord), '[]'::jsonb) into imgs
    from unnest(coalesce(p_paths, '{}')) with ordinality u(path, ord) join media_assets m on m.path = u.path;
  update products set images = imgs, updated_at = now() where code = p_code;
  perform _audit('product.images', 'product', p_code, p_reason, old, imgs);
end $$;

create function admin_delete_media(p_id uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare a media_assets;
begin
  perform _require('media.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into a from media_assets where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if exists (select 1 from products where jsonb_typeof(images) = 'array' and images @> jsonb_build_array(jsonb_build_object('path', a.path))) then raise exception 'in_use'; end if;
  delete from media_assets where id = p_id;
  perform _audit('media.delete', 'media', p_id::text, p_reason, to_jsonb(a), null);
  return a.path;
end $$;

create function admin_list_media() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('media.manage');
  return jsonb_build_object(
    'media', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'path', m.path, 'alt', m.alt_text, 'created_at', m.created_at,
        'used_by', coalesce((select jsonb_agg(p.code) from products p where jsonb_typeof(p.images) = 'array' and p.images @> jsonb_build_array(jsonb_build_object('path', m.path))), '[]'::jsonb))
        order by m.created_at desc) from media_assets m), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name,
        'paths', coalesce((select jsonb_agg(e->>'path') from jsonb_array_elements(case when jsonb_typeof(p.images) = 'array' then p.images else '[]'::jsonb end) e), '[]'::jsonb)) order by p.code) from products p), '[]'::jsonb));
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_register_media(text,text,text)', 'admin_update_media_alt(uuid,text,text)', 'admin_set_product_images(text,text[],text)', 'admin_delete_media(uuid,text)', 'admin_list_media()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
