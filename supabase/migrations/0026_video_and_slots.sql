update storage.buckets set allowed_mime_types = array['image/jpeg','image/png','image/webp','image/avif','video/mp4','video/webm'], file_size_limit = 52428800 where id = 'product-media';

alter table media_assets
  add column kind text not null default 'image' check (kind in ('image', 'video', 'embed')),
  add column poster_path text,
  add column embed_url text;
alter table media_assets alter column path drop not null;
alter table media_assets add constraint media_kind_shape check (
  (kind = 'embed' and path is null and embed_url is not null) or (kind <> 'embed' and path is not null));

create table media_slots (
  slot text primary key,
  label text not null,
  media_id uuid references media_assets(id) on delete set null,
  updated_at timestamptz not null default now()
);
insert into media_slots (slot, label) values
  ('home.hero', 'Home page: film under the headline'),
  ('launch.hero', 'Launch page: opening film'),
  ('launch.story', 'Launch page: story section'),
  ('philosophy.banner', 'Philosophy page: banner'),
  ('society.banner', 'Society page: banner');
alter table media_slots enable row level security;
revoke all on media_slots from anon, authenticated;

create function _embed_url(p text) returns text language plpgsql immutable as $$
declare m text[];
begin
  m := regexp_match(coalesce(p, ''), '^https://(?:www\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([A-Za-z0-9_-]{11})(?:[&?].*)?$');
  if m is not null then return 'https://www.youtube-nocookie.com/embed/' || m[1]; end if;
  m := regexp_match(coalesce(p, ''), '^https://(?:www\.)?vimeo\.com/([0-9]{5,12})(?:[/?].*)?$');
  if m is not null then return 'https://player.vimeo.com/video/' || m[1]; end if;
  return null;
end $$;

create function admin_register_video(p_path text, p_poster text, p_alt text, p_reason text) returns uuid
language plpgsql security definer set search_path = public, storage as $$
declare rid uuid;
begin
  perform _require('media.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if length(trim(coalesce(p_alt, ''))) < 3 or length(p_alt) > 200 then raise exception 'alt_required'; end if;
  if p_path !~ '^videos/[a-f0-9-]{36}\.(mp4|webm)$' then raise exception 'invalid_path'; end if;
  if p_poster is not null and p_poster !~ '^posters/[a-f0-9-]{36}\.(jpg|jpeg|png|webp|avif)$' then raise exception 'invalid_path'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'product-media' and name = p_path) then raise exception 'file_missing'; end if;
  if p_poster is not null and not exists (select 1 from storage.objects where bucket_id = 'product-media' and name = p_poster) then raise exception 'file_missing'; end if;
  insert into media_assets (kind, path, poster_path, alt_text, uploaded_by) values ('video', p_path, p_poster, trim(p_alt), current_customer_id()) returning id into rid;
  perform _audit('media.register', 'media', rid::text, p_reason, null, jsonb_build_object('kind', 'video', 'path', p_path, 'alt', trim(p_alt)));
  return rid;
end $$;

create function admin_register_embed(p_url text, p_alt text, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; u text := _embed_url(trim(coalesce(p_url, '')));
begin
  perform _require('media.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if length(trim(coalesce(p_alt, ''))) < 3 or length(p_alt) > 200 then raise exception 'alt_required'; end if;
  if u is null then raise exception 'invalid_embed'; end if;
  insert into media_assets (kind, embed_url, alt_text, uploaded_by) values ('embed', u, trim(p_alt), current_customer_id()) returning id into rid;
  perform _audit('media.register', 'media', rid::text, p_reason, null, jsonb_build_object('kind', 'embed', 'url', u, 'alt', trim(p_alt)));
  return rid;
end $$;

create function admin_set_media_slot(p_slot text, p_media uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old uuid;
begin
  perform _require('media.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select media_id into old from media_slots where slot = p_slot for update;
  if not found then raise exception 'not_found'; end if;
  if p_media is not null and not exists (select 1 from media_assets where id = p_media) then raise exception 'not_found'; end if;
  update media_slots set media_id = p_media, updated_at = now() where slot = p_slot;
  perform _audit('media.slot', 'media_slot', p_slot, p_reason, to_jsonb(old), to_jsonb(p_media));
end $$;

create function public_media_slots() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(s.slot, jsonb_build_object('kind', m.kind, 'path', m.path, 'poster', m.poster_path, 'embed', m.embed_url, 'alt', m.alt_text)), '{}'::jsonb)
    from media_slots s join media_assets m on m.id = s.media_id $$;

-- product images stay images only
create or replace function admin_set_product_images(p_code text, p_paths text[], p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare imgs jsonb; old jsonb;
begin
  perform _require('catalog.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if coalesce(array_length(p_paths, 1), 0) > 8 then raise exception 'too_many'; end if;
  select images into old from products where code = p_code for update;
  if not found then raise exception 'not_found'; end if;
  if exists (select 1 from unnest(coalesce(p_paths, '{}')) x where not exists (select 1 from media_assets m where m.path = x and m.kind = 'image')) then raise exception 'unknown_media'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('path', m.path, 'alt', m.alt_text) order by u.ord), '[]'::jsonb) into imgs
    from unnest(coalesce(p_paths, '{}')) with ordinality u(path, ord) join media_assets m on m.path = u.path;
  update products set images = imgs, updated_at = now() where code = p_code;
  perform _audit('product.images', 'product', p_code, p_reason, old, imgs);
end $$;

-- delete now also refuses placed media and returns every storage file to remove
drop function admin_delete_media(uuid, text);
create function admin_delete_media(p_id uuid, p_reason text) returns text[]
language plpgsql security definer set search_path = public as $$
declare a media_assets;
begin
  perform _require('media.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into a from media_assets where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if a.path is not null and exists (select 1 from products where jsonb_typeof(images) = 'array' and images @> jsonb_build_array(jsonb_build_object('path', a.path))) then raise exception 'in_use'; end if;
  if exists (select 1 from media_slots where media_id = p_id) then raise exception 'in_use'; end if;
  delete from media_assets where id = p_id;
  perform _audit('media.delete', 'media', p_id::text, p_reason, to_jsonb(a), null);
  return array_remove(array[a.path, a.poster_path], null);
end $$;

create or replace function admin_list_media() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('media.manage');
  return jsonb_build_object(
    'media', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'path', m.path, 'poster', m.poster_path, 'embed', m.embed_url, 'alt', m.alt_text, 'created_at', m.created_at,
        'used_by', coalesce((select jsonb_agg(p.code) from products p where m.path is not null and jsonb_typeof(p.images) = 'array' and p.images @> jsonb_build_array(jsonb_build_object('path', m.path))), '[]'::jsonb)
                    || coalesce((select jsonb_agg(s.slot) from media_slots s where s.media_id = m.id), '[]'::jsonb))
        order by m.created_at desc) from media_assets m), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name,
        'paths', coalesce((select jsonb_agg(e->>'path') from jsonb_array_elements(case when jsonb_typeof(p.images) = 'array' then p.images else '[]'::jsonb end) e), '[]'::jsonb)) order by p.code) from products p), '[]'::jsonb),
    'slots', coalesce((select jsonb_agg(jsonb_build_object('slot', s.slot, 'label', s.label, 'media_id', s.media_id) order by s.slot) from media_slots s), '[]'::jsonb));
end $$;

revoke execute on function public._embed_url(text) from public, anon, authenticated;
revoke execute on function public.admin_register_video(text, text, text, text), public.admin_register_embed(text, text, text), public.admin_set_media_slot(text, uuid, text),
  public.admin_delete_media(uuid, text), public.admin_list_media(), public.admin_set_product_images(text, text[], text) from public, anon;
grant execute on function public.admin_register_video(text, text, text, text), public.admin_register_embed(text, text, text), public.admin_set_media_slot(text, uuid, text),
  public.admin_delete_media(uuid, text), public.admin_list_media(), public.admin_set_product_images(text, text[], text) to authenticated;
revoke execute on function public.public_media_slots() from public;
grant execute on function public.public_media_slots() to anon, authenticated;
