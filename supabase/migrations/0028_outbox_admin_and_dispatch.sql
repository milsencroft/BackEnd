insert into role_permissions (role, permission) values ('admin', 'notifications.manage') on conflict do nothing;

create function admin_outbox_overview(p_status text default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('notifications.view');
  return jsonb_build_object(
    'counts', coalesce((select jsonb_object_agg(s, n) from (select status::text s, count(*) n from notification_outbox group by 1) x), '{}'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from (
        select id, event_id, channel, recipient, template, status, attempts, next_attempt_at, last_error, created_at, sent_at, delivered_at, payload->>'order_number' as order_number
          from notification_outbox where p_status is null or status::text = p_status order by created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) i), '[]'::jsonb));
end $$;

create function admin_outbox_retry(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o notification_outbox;
begin
  perform _require('notifications.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into o from notification_outbox where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if o.status <> 'failed' then raise exception 'not_failed'; end if;
  update notification_outbox set status = 'pending', next_attempt_at = now(), attempts = 0 where id = p_id;
  perform _audit('notification.retry', 'notification', p_id::text, p_reason, jsonb_build_object('error', o.last_error, 'attempts', o.attempts), null);
end $$;

create function admin_outbox_cancel(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o notification_outbox;
begin
  perform _require('notifications.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into o from notification_outbox where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if o.status not in ('pending', 'failed') then raise exception 'not_cancellable'; end if;
  update notification_outbox set status = 'cancelled' where id = p_id;
  perform _audit('notification.cancel', 'notification', p_id::text, p_reason, to_jsonb(o.status), null);
end $$;

-- For the future sender (service role only). Claims due messages with a 10 minute lease so two workers never send the same one.
create function outbox_claim(p_limit int default 20, p_channel text default null) returns setof notification_outbox
language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select id from notification_outbox where status = 'pending' and next_attempt_at <= now() and (p_channel is null or channel = p_channel)
     order by next_attempt_at limit least(greatest(coalesce(p_limit, 20), 1), 100) for update skip locked)
  update notification_outbox n set attempts = n.attempts + 1, next_attempt_at = now() + interval '10 minutes'
    from due where n.id = due.id returning n.*;
end $$;

create function outbox_mark_sent(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update notification_outbox set status = 'sent', sent_at = now(), last_error = null where id = p_id and status = 'pending' $$;

-- Retries with growing delay (2, 4, 8, 16 minutes); fails visibly after 5 attempts.
create function outbox_mark_failed(p_id uuid, p_error text) returns void
language plpgsql security definer set search_path = public as $$
declare a int;
begin
  select attempts into a from notification_outbox where id = p_id and status = 'pending' for update;
  if not found then return; end if;
  if a >= 5 then
    update notification_outbox set status = 'failed', last_error = left(coalesce(p_error, 'unknown error'), 500) where id = p_id;
  else
    update notification_outbox set last_error = left(coalesce(p_error, 'unknown error'), 500), next_attempt_at = now() + (power(2, a)::int || ' minutes')::interval where id = p_id;
  end if;
end $$;

-- Only a delivery receipt from the channel provider may mark a message delivered.
create function outbox_mark_delivered(p_event_id text) returns void
language sql security definer set search_path = public as $$
  update notification_outbox set status = 'delivered', delivered_at = now() where event_id = p_event_id and status in ('sent', 'pending') and delivered_at is null $$;

revoke execute on function public.admin_outbox_overview(text, int), public.admin_outbox_retry(uuid, text), public.admin_outbox_cancel(uuid, text) from public, anon;
grant execute on function public.admin_outbox_overview(text, int), public.admin_outbox_retry(uuid, text), public.admin_outbox_cancel(uuid, text) to authenticated;
revoke execute on function public.outbox_claim(int, text), public.outbox_mark_sent(uuid), public.outbox_mark_failed(uuid, text), public.outbox_mark_delivered(text) from public, anon, authenticated;
grant execute on function public.outbox_claim(int, text), public.outbox_mark_sent(uuid), public.outbox_mark_failed(uuid, text), public.outbox_mark_delivered(text) to service_role;
