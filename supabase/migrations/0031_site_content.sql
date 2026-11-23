create table site_pages (
  slug text primary key check (slug ~ '^[a-z0-9-]{2,60}$'),
  kind text not null check (kind in ('page', 'legal', 'journal')),
  title text not null check (length(title) between 1 and 160),
  summary text check (length(summary) <= 400),
  body text not null default '' check (length(body) <= 20000),
  status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  published_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table site_pages enable row level security;
revoke all on site_pages from anon, authenticated;

insert into role_permissions (role, permission) values ('admin', 'content.manage'), ('content_manager', 'content.manage') on conflict do nothing;

create function admin_list_pages() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('content.manage');
  return coalesce((select jsonb_agg(to_jsonb(p) order by p.kind, p.slug) from site_pages p), '[]'::jsonb);
end $$;

create function admin_save_page(p_slug text, p_kind text, p_title text, p_summary text, p_body text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare before jsonb; me uuid;
begin
  perform _require('content.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_slug !~ '^[a-z0-9-]{2,60}$' or p_kind not in ('page', 'legal', 'journal') or coalesce(trim(p_title), '') = '' or length(p_title) > 160 or length(coalesce(p_body, '')) > 20000 or length(coalesce(p_summary, '')) > 400 then raise exception 'invalid_input'; end if;
  select to_jsonb(s) into before from site_pages s where slug = p_slug;
  select id into me from customers where auth_user_id = auth.uid();
  insert into site_pages (slug, kind, title, summary, body, updated_by) values (p_slug, p_kind, trim(p_title), nullif(trim(p_summary), ''), coalesce(p_body, ''), me)
    on conflict (slug) do update set kind = excluded.kind, title = excluded.title, summary = excluded.summary, body = excluded.body, updated_at = now(), updated_by = me;
  perform _audit('content.save', 'site_page', p_slug, p_reason, before, jsonb_build_object('title', p_title, 'kind', p_kind));
end $$;

create function admin_set_page_status(p_slug text, p_status text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old text;
begin
  perform _require('content.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_status not in ('draft', 'published', 'archived') then raise exception 'invalid_input'; end if;
  select status into old from site_pages where slug = p_slug for update;
  if not found then raise exception 'not_found'; end if;
  update site_pages set status = p_status, updated_at = now(),
    published_at = case when p_status = 'published' then coalesce(published_at, now()) else published_at end where slug = p_slug;
  perform _audit('content.status', 'site_page', p_slug, p_reason, jsonb_build_object('status', old), jsonb_build_object('status', p_status));
end $$;

-- Public readers return published pages only, so drafts and archived pages never render.
create function public_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(x) from (select slug, kind, title, summary, body, published_at from site_pages where slug = p_slug and status = 'published') x;
$$;
create function public_pages(p_kind text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.published_at desc), '[]'::jsonb)
  from (select slug, kind, title, summary, published_at from site_pages where kind = p_kind and status = 'published') x;
$$;

revoke execute on function public.admin_list_pages(), public.admin_save_page(text,text,text,text,text,text), public.admin_set_page_status(text,text,text) from public, anon;
grant execute on function public.admin_list_pages(), public.admin_save_page(text,text,text,text,text,text), public.admin_set_page_status(text,text,text) to authenticated;
revoke execute on function public.public_page(text), public.public_pages(text) from public;
grant execute on function public.public_page(text), public.public_pages(text) to anon, authenticated;
