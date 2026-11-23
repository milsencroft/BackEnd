create table rate_limits (
  key text not null,
  window_start timestamptz not null,
  hits int not null default 0,
  primary key (key, window_start)
);
alter table rate_limits enable row level security;
revoke all on rate_limits from anon, authenticated;

-- Returns true while the caller is within the limit. Fixed windows; old rows are swept now and then.
create function rate_limit_hit(p_key text, p_limit int, p_window_seconds int) returns boolean
language plpgsql security definer set search_path = public as $$
declare w timestamptz; h int;
begin
  if p_limit < 1 or p_window_seconds < 1 then raise exception 'invalid_input'; end if;
  w := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into rate_limits (key, window_start, hits) values (left(p_key, 200), w, 1)
    on conflict (key, window_start) do update set hits = rate_limits.hits + 1 returning hits into h;
  if random() < 0.02 then delete from rate_limits where window_start < now() - interval '2 days'; end if;
  return h <= p_limit;
end $$;
revoke execute on function public.rate_limit_hit(text, int, int) from public, anon, authenticated;
grant execute on function public.rate_limit_hit(text, int, int) to service_role;

create table newsletter_subscribers (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  source text not null default 'website',
  consent_text text not null,
  consented_at timestamptz not null default now(),
  confirmed_at timestamptz,
  unsubscribed_at timestamptz
);
create unique index newsletter_email_key on newsletter_subscribers (lower(email));
alter table newsletter_subscribers enable row level security;
revoke all on newsletter_subscribers from anon, authenticated;

insert into role_permissions (role, permission) values ('admin', 'newsletter.manage'), ('content_manager', 'newsletter.manage') on conflict do nothing;

-- Always answers 'ok' so the form never reveals who is already subscribed.
create function newsletter_subscribe(p_email text, p_source text default 'website') returns text
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email, ''))); consent constant text := 'I agree to receive occasional news from Milsen & Croft. I can unsubscribe at any time.';
begin
  if length(e) > 200 or e !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then raise exception 'invalid_email'; end if;
  if not rate_limit_hit('newsletter:all', 120, 3600) or not rate_limit_hit('newsletter:' || e, 3, 86400) then raise exception 'rate_limited'; end if;
  insert into newsletter_subscribers (email, source, consent_text) values (e, left(coalesce(p_source, 'website'), 40), consent)
    on conflict (lower(email)) do update set unsubscribed_at = null, consented_at = now(), consent_text = consent
      where newsletter_subscribers.unsubscribed_at is not null;
  return 'ok';
end $$;
revoke execute on function public.newsletter_subscribe(text, text) from public;
grant execute on function public.newsletter_subscribe(text, text) to anon, authenticated;

create function admin_newsletter_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('newsletter.manage');
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'email', email, 'source', source, 'consented_at', consented_at, 'confirmed_at', confirmed_at, 'unsubscribed_at', unsubscribed_at) order by consented_at desc) from newsletter_subscribers), '[]'::jsonb);
end $$;

create function admin_newsletter_unsubscribe(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require('newsletter.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  update newsletter_subscribers set unsubscribed_at = now() where id = p_id and unsubscribed_at is null;
  if not found then raise exception 'not_found'; end if;
  perform _audit('newsletter.unsubscribe', 'newsletter', p_id::text, p_reason, null, null);
end $$;
revoke execute on function public.admin_newsletter_list(), public.admin_newsletter_unsubscribe(uuid, text) from public, anon;
grant execute on function public.admin_newsletter_list(), public.admin_newsletter_unsubscribe(uuid, text) to authenticated;
