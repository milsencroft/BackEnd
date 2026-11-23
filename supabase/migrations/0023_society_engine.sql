-- Society progression engine: promotion, queues, missed launches, demotion, re-entry, dispatch tracking.
alter table society_tiers add column benefits text not null default '';
update society_tiers set benefits = case tier
  when 1 then 'Numbered card, certificate, collector package and Society access.'
  when 2 then 'Updated card and certificate, and selected early access.'
  when 3 then 'Discovery offers, previews and announcements.'
  when 4 then 'Priority limited releases and selected offers.'
  when 5 then 'Private previews and exclusive products or experiences.'
  when 6 then 'Store-opening invitations, VIP shopping, private events and selected exclusive products.' end;

alter table society_memberships
  add column missed_count int not null default 0,
  add column last_launch_id uuid references launches(id),
  add column card_dispatched_at timestamptz,
  add column package_dispatched_at timestamptz;
update society_memberships set last_launch_id = launch_id;

alter table society_membership_history add column membership_number text;
update society_membership_history h set membership_number = m.membership_number
  from society_memberships m where m.id = h.membership_id and h.membership_number is null;

alter table society_waiting_list
  add column qualifying_at timestamptz not null default now(),
  add column launch_id uuid references launches(id);

create table society_launch_cycles (
  launch_id uuid primary key references launches(id),
  processed_at timestamptz not null default now(),
  processed_by uuid,
  summary jsonb not null default '{}'
);
alter table society_launch_cycles enable row level security;
revoke all on society_launch_cycles from anon, authenticated;

create function _society_next_number(p_prefix text) returns text
language sql security definer set search_path = public as $$
  select p_prefix || lpad((coalesce(max(substr(n, length(p_prefix) + 1)::int), 0) + 1)::text, 3, '0')
    from (select membership_number n from society_memberships
          union select membership_number from society_membership_history where membership_number is not null) x
   where n like p_prefix || '%' and substr(n, length(p_prefix) + 1) ~ '^[0-9]+$' $$;

create function _society_move_up(p_membership uuid, p_to int, p_launch uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare m society_memberships; l launches; v_num text;
begin
  select * into m from society_memberships where id = p_membership for update;
  select * into l from launches where id = p_launch;
  v_num := _society_next_number('MS-' || l.code || '-T' || p_to || '-');
  update society_memberships set tier = p_to, membership_number = v_num, last_launch_id = p_launch, missed_count = 0 where id = p_membership;
  insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number)
  values (m.id, m.customer_id, m.tier, p_to, p_reason, v_num);
end $$;

create function _society_fill_queue(p_tier int) returns void
language plpgsql security definer set search_path = public as $$
declare t society_tiers; w society_waiting_list; m society_memberships;
begin
  if p_tier < 2 then return; end if;   -- Tier 1 re-entry is never automatic
  select * into t from society_tiers where tier = p_tier for update;
  if not found then return; end if;
  delete from society_waiting_list q where q.tier = p_tier and not exists
    (select 1 from society_memberships s where s.customer_id = q.customer_id and s.status = 'active' and s.tier = p_tier - 1);
  loop
    exit when (select count(*) from society_memberships where tier = p_tier and status = 'active') >= t.cap;
    select * into w from society_waiting_list where tier = p_tier order by qualifying_at, created_at limit 1 for update;
    exit when not found;
    select * into m from society_memberships where customer_id = w.customer_id and status = 'active';
    perform _society_move_up(m.id, p_tier, coalesce(w.launch_id, m.last_launch_id, m.launch_id), 'Advanced from tier queue');
    delete from society_waiting_list where id = w.id;
    perform _society_fill_queue(p_tier - 1);
  end loop;
end $$;

-- Called when a customer's participation in a launch is recorded. New customers are handled by grant_membership.
create function _society_apply(p_customer uuid, p_launch uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l launches; m society_memberships; t society_tiers; target int;
begin
  select * into l from launches where id = p_launch;
  if not found or not l.society_eligible then return; end if;
  select * into m from society_memberships where customer_id = p_customer and status = 'active' for update;
  if not found then return; end if;
  if m.launch_id = p_launch or m.last_launch_id = p_launch then return; end if;
  update society_memberships set missed_count = 0, last_launch_id = p_launch where id = m.id;
  if m.tier >= 6 then
    insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number)
    values (m.id, m.customer_id, m.tier, m.tier, 'Took part in launch ' || l.code || ' (top tier)', m.membership_number);
    return;
  end if;
  target := m.tier + 1;
  select * into t from society_tiers where tier = target for update;
  if (select count(*) from society_memberships where tier = target and status = 'active') < t.cap then
    perform _society_move_up(m.id, target, p_launch, 'Promoted via launch ' || l.code);
    perform _society_fill_queue(m.tier);
  else
    insert into society_waiting_list (customer_id, tier, launch_id) values (p_customer, target, p_launch) on conflict (customer_id, tier) do nothing;
    insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number)
    values (m.id, m.customer_id, m.tier, m.tier, 'Qualified for tier ' || target || ' via launch ' || l.code || '; queued, tier is full', m.membership_number);
  end if;
end $$;

-- A failure here must never block a payment, so errors are logged and swallowed; the launch cycle re-applies it.
create function _society_participation_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin perform _society_apply(new.customer_id, new.launch_id);
  exception when others then raise warning 'society_apply failed: %', sqlerrm;
  end;
  return new;
end $$;
create trigger trg_society_participation after insert on launch_participations
  for each row execute function _society_participation_trigger();

-- grant_membership: same behaviour, plus lapsed members re-enter only via the waiting list, and safer numbering.
create or replace function grant_membership(p_customer uuid, p_launch uuid, p_tier integer default 1)
returns table(r_result text, r_membership_id uuid, r_number text)
language plpgsql security definer set search_path = public as $$
declare t society_tiers%rowtype; l launches%rowtype; v_id uuid; v_num text; v_active int;
begin
  select * into t from society_tiers where tier = p_tier for update;
  if not found then return query select 'invalid_tier'::text, null::uuid, null::text; return; end if;
  select * into l from launches where id = p_launch;
  if not found then return query select 'not_found'::text, null::uuid, null::text; return; end if;

  select m.id, m.membership_number into v_id, v_num from society_memberships m where m.customer_id = p_customer and m.status = 'active';
  if found then return query select 'existing'::text, v_id, v_num; return; end if;

  if exists (select 1 from society_memberships m where m.customer_id = p_customer and m.status = 'lapsed') then
    insert into society_waiting_list (customer_id, tier, launch_id) values (p_customer, 1, p_launch) on conflict do nothing;
    return query select 'waitlisted'::text, null::uuid, null::text; return;
  end if;

  select count(*) into v_active from society_memberships m where m.tier = p_tier and m.status = 'active';
  if v_active >= t.cap then
    insert into society_waiting_list (customer_id, tier, launch_id) values (p_customer, p_tier, p_launch) on conflict do nothing;
    return query select 'waitlisted'::text, null::uuid, null::text; return;
  end if;

  v_num := _society_next_number('MS-' || l.code || '-T' || p_tier || '-');
  insert into society_memberships (customer_id, tier, launch_id, membership_number, last_launch_id)
  values (p_customer, p_tier, p_launch, v_num, p_launch) returning id into v_id;
  insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number)
  values (v_id, p_customer, null, p_tier, 'Joined via launch ' || l.code, v_num);
  delete from society_waiting_list where customer_id = p_customer and tier = p_tier;
  return query select 'granted'::text, v_id, v_num;
end $$;

create function admin_process_launch_cycle(p_launch uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l launches; r record; cur society_memberships; trow society_tiers; cutoff timestamptz;
  v_missed int := 0; v_demoted int := 0; v_ended int := 0; v_dest int; x int; summary jsonb;
begin
  perform _require('society.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into l from launches where id = p_launch for update;
  if not found then raise exception 'not_found'; end if;
  if not l.society_eligible then raise exception 'not_eligible'; end if;
  if l.status not in ('closed', 'post_launch_review', 'published_in_shop', 'completed') then raise exception 'launch_not_finished'; end if;
  if exists (select 1 from society_launch_cycles where launch_id = p_launch) then raise exception 'already_processed'; end if;
  cutoff := coalesce(l.closed_at, now());

  for r in select customer_id from launch_participations where launch_id = p_launch loop
    perform _society_apply(r.customer_id, p_launch);
  end loop;

  for r in select sm.id from society_memberships sm
            where sm.status = 'active' and sm.launch_id <> p_launch and sm.joined_at < cutoff
              and not exists (select 1 from launch_participations lp where lp.launch_id = p_launch and lp.customer_id = sm.customer_id)
            order by sm.tier desc, sm.joined_at loop
    select * into cur from society_memberships where id = r.id for update;
    if cur.status <> 'active' then continue; end if;
    update society_memberships set missed_count = cur.missed_count + 1 where id = cur.id;
    v_missed := v_missed + 1;
    insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number)
    values (cur.id, cur.customer_id, cur.tier, cur.tier, 'Missed launch ' || l.code || ' (' || (cur.missed_count + 1) || ' in a row)', cur.membership_number);
    if cur.missed_count + 1 >= 2 then
      v_dest := null;
      if cur.tier >= 2 then
        for x in reverse cur.tier - 1 .. 1 loop
          select * into trow from society_tiers where tier = x for update;
          if (select count(*) from society_memberships where tier = x and status = 'active') < trow.cap then v_dest := x; exit; end if;
        end loop;
      end if;
      if v_dest is not null then
        update society_memberships set tier = v_dest, missed_count = 0 where id = cur.id;
        insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number)
        values (cur.id, cur.customer_id, cur.tier, v_dest, 'Moved down after two missed launches in a row', cur.membership_number);
        v_demoted := v_demoted + 1;
      else
        update society_memberships set status = 'lapsed', ended_at = now(), missed_count = 0 where id = cur.id;
        insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number)
        values (cur.id, cur.customer_id, cur.tier, null, 'Membership ended after two missed launches in a row; added to the Tier 1 re-entry list', cur.membership_number);
        insert into society_waiting_list (customer_id, tier, launch_id) values (cur.customer_id, 1, p_launch)
          on conflict (customer_id, tier) do update set created_at = now(), qualifying_at = now();
        v_ended := v_ended + 1;
      end if;
    end if;
  end loop;

  for x in reverse 6 .. 2 loop perform _society_fill_queue(x); end loop;

  summary := jsonb_build_object('missed', v_missed, 'demoted', v_demoted, 'ended', v_ended);
  insert into society_launch_cycles (launch_id, processed_by, summary) values (p_launch, current_customer_id(), summary);
  perform _audit('society.cycle', 'launch', p_launch::text, p_reason, null, summary);
  return summary;
end $$;

create function admin_society_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('society.manage');
  return jsonb_build_object(
    'tiers', (select jsonb_agg(jsonb_build_object('tier', t.tier, 'name', t.name, 'cap', t.cap, 'benefits', t.benefits,
        'active', (select count(*) from society_memberships m where m.tier = t.tier and m.status = 'active'),
        'queue', (select count(*) from society_waiting_list w where w.tier = t.tier)) order by t.tier) from society_tiers t),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'number', m.membership_number, 'tier', m.tier, 'status', m.status,
        'missed', m.missed_count, 'joined_at', m.joined_at, 'ended_at', m.ended_at, 'card_dispatched_at', m.card_dispatched_at,
        'package_dispatched_at', m.package_dispatched_at, 'name', c.full_name, 'email', c.email) order by m.tier desc, m.joined_at)
        from society_memberships m join customers c on c.id = m.customer_id), '[]'),
    'waiting', coalesce((select jsonb_agg(jsonb_build_object('customer_id', c.id, 'name', c.full_name, 'email', c.email, 'tier', w.tier,
        'since', w.qualifying_at) order by w.tier, w.qualifying_at) from society_waiting_list w join customers c on c.id = w.customer_id), '[]'),
    'launches', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'code', l.code, 'name', l.name, 'status', l.status,
        'processed', exists (select 1 from society_launch_cycles x where x.launch_id = l.id)) order by l.created_at desc)
        from launches l where l.society_eligible and l.status in ('closed', 'post_launch_review', 'published_in_shop', 'completed')), '[]'));
end $$;

create function my_society() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cid uuid := _my_customer(); m society_memberships;
begin
  if cid is null then raise exception 'forbidden'; end if;
  select * into m from society_memberships where customer_id = cid and status = 'active';
  return jsonb_build_object(
    'membership', case when m.id is null then null else jsonb_build_object('number', m.membership_number, 'tier', m.tier,
        'tier_name', (select name from society_tiers where tier = m.tier), 'benefits', (select benefits from society_tiers where tier = m.tier),
        'joined_at', m.joined_at, 'missed', m.missed_count, 'launch_code', (select code from launches where id = m.launch_id),
        'card_dispatched_at', m.card_dispatched_at, 'package_dispatched_at', m.package_dispatched_at) end,
    'lapsed', m.id is null and exists (select 1 from society_memberships where customer_id = cid and status = 'lapsed'),
    'queue', coalesce((select jsonb_agg(jsonb_build_object('tier', w.tier, 'tier_name', t.name, 'since', w.qualifying_at))
        from society_waiting_list w join society_tiers t on t.tier = w.tier where w.customer_id = cid), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', h.created_at, 'from', h.from_tier, 'to', h.to_tier, 'reason', h.reason,
        'number', h.membership_number) order by h.created_at desc) from society_membership_history h where h.customer_id = cid), '[]'));
end $$;

create function admin_admit_reentry(p_customer uuid, p_launch uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare l launches; t society_tiers; v_num text; v_id uuid;
begin
  perform _require('society.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  select * into l from launches where id = p_launch;
  if not found then raise exception 'not_found'; end if;
  if not exists (select 1 from society_waiting_list where customer_id = p_customer and tier = 1) then raise exception 'not_waiting'; end if;
  if exists (select 1 from society_memberships where customer_id = p_customer and status = 'active') then raise exception 'already_member'; end if;
  select * into t from society_tiers where tier = 1 for update;
  if (select count(*) from society_memberships where tier = 1 and status = 'active') >= t.cap then raise exception 'tier_full'; end if;
  v_num := _society_next_number('MS-' || l.code || '-T1-');
  insert into society_memberships (customer_id, tier, launch_id, membership_number, last_launch_id)
  values (p_customer, 1, p_launch, v_num, p_launch) returning id into v_id;
  insert into society_membership_history (membership_id, customer_id, from_tier, to_tier, reason, membership_number, actor_customer_id)
  values (v_id, p_customer, null, 1, 'Admitted from the Tier 1 waiting list: ' || trim(p_reason), v_num, current_customer_id());
  delete from society_waiting_list where customer_id = p_customer and tier = 1;
  perform _audit('society.admit', 'society_membership', v_id::text, p_reason, null, jsonb_build_object('number', v_num));
  return v_num;
end $$;

create function admin_society_dispatch(p_membership uuid, p_item text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require('society.manage');
  if p_item not in ('card', 'package') or coalesce(trim(p_reason), '') = '' then raise exception 'invalid_input'; end if;
  update society_memberships set card_dispatched_at = case when p_item = 'card' then now() else card_dispatched_at end,
    package_dispatched_at = case when p_item = 'package' then now() else package_dispatched_at end where id = p_membership;
  if not found then raise exception 'not_found'; end if;
  perform _audit('society.dispatch', 'society_membership', p_membership::text, p_reason, null, jsonb_build_object('item', p_item));
end $$;

create function admin_set_tier_benefits(p_tier int, p_benefits text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare old text;
begin
  perform _require('society.manage');
  if coalesce(trim(p_reason), '') = '' or length(coalesce(p_benefits, '')) > 600 then raise exception 'invalid_input'; end if;
  select benefits into old from society_tiers where tier = p_tier for update;
  if not found then raise exception 'not_found'; end if;
  update society_tiers set benefits = trim(coalesce(p_benefits, '')) where tier = p_tier;
  perform _audit('society.benefits', 'society_tier', p_tier::text, p_reason, to_jsonb(old), to_jsonb(trim(coalesce(p_benefits, ''))));
end $$;

create function admin_run_society_queues(p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare x int;
begin
  perform _require('society.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  for x in reverse 6 .. 2 loop perform _society_fill_queue(x); end loop;
  perform _audit('society.queues', 'society', 'queues', p_reason, null, null);
end $$;

do $$ declare f text; begin
  foreach f in array array['_society_next_number(text)', '_society_move_up(uuid,int,uuid,text)', '_society_fill_queue(int)', '_society_apply(uuid,uuid)', '_society_participation_trigger()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['admin_process_launch_cycle(uuid,text)', 'admin_society_overview()', 'my_society()', 'admin_admit_reentry(uuid,uuid,text)',
    'admin_society_dispatch(uuid,text,text)', 'admin_set_tier_benefits(int,text,text)', 'admin_run_society_queues(text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
