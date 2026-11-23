create function admin_list_coupons() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('coupons.manage');
  return coalesce((select jsonb_agg(to_jsonb(c) - 'id' || jsonb_build_object('redeemed', (select count(*) from orders o where o.coupon_code = c.code and o.payment_status in ('captured', 'refund_pending', 'refunded')))
                  order by c.created_at desc) from coupons c), '[]');
end $$;

-- One custom code (p_code) or p_count random codes (optional prefix). Random codes are single-use unless p_max_uses is given.
create function admin_create_coupons(p_code text, p_count int, p_prefix text, p_discount_type text, p_value int, p_min_order_paise int,
  p_max_uses int, p_starts_at timestamptz, p_ends_at timestamptz, p_allow_on_launch boolean, p_reason text) returns text[]
language plpgsql security definer set search_path = public as $$
declare codes text[] := '{}'; c text; n int := 0; tries int := 0;
begin
  perform _require('coupons.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  if p_discount_type not in ('percent', 'flat') or p_value is null or p_value <= 0 or (p_discount_type = 'percent' and p_value > 100) then raise exception 'invalid_input'; end if;
  if coalesce(p_min_order_paise, 0) < 0 or (p_max_uses is not null and p_max_uses <= 0) or (p_ends_at is not null and p_starts_at is not null and p_ends_at <= p_starts_at) then raise exception 'invalid_input'; end if;
  if nullif(trim(coalesce(p_code, '')), '') is not null then
    c := upper(trim(p_code));
    if c !~ '^[A-Z0-9-]{3,30}$' then raise exception 'invalid_code'; end if;
    if exists (select 1 from coupons where code = c) then raise exception 'duplicate_code'; end if;
    insert into coupons (code, discount_type, value, min_order_paise, max_uses, starts_at, ends_at, allow_on_launch)
    values (c, p_discount_type, p_value, coalesce(p_min_order_paise, 0), p_max_uses, p_starts_at, p_ends_at, coalesce(p_allow_on_launch, false));
    codes := array[c];
  else
    if p_count is null or p_count < 1 or p_count > 500 then raise exception 'invalid_input'; end if;
    if coalesce(p_prefix, '') !~ '^[A-Za-z0-9-]{0,12}$' then raise exception 'invalid_code'; end if;
    while n < p_count loop
      tries := tries + 1; if tries > p_count * 5 then raise exception 'could_not_generate'; end if;
      c := upper(coalesce(p_prefix, '')) || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
      begin
        insert into coupons (code, discount_type, value, min_order_paise, max_uses, starts_at, ends_at, allow_on_launch)
        values (c, p_discount_type, p_value, coalesce(p_min_order_paise, 0), coalesce(p_max_uses, 1), p_starts_at, p_ends_at, coalesce(p_allow_on_launch, false));
        codes := codes || c; n := n + 1;
      exception when unique_violation then null;
      end;
    end loop;
  end if;
  perform _audit('coupon.create', 'coupon', array_to_string(codes[1:3], ','), p_reason, null,
    jsonb_build_object('count', array_length(codes, 1), 'type', p_discount_type, 'value', p_value));
  return codes;
end $$;

create function admin_set_coupon_active(p_code text, p_active boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require('coupons.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required'; end if;
  update coupons set is_active = p_active where code = upper(trim(p_code));
  if not found then raise exception 'not_found'; end if;
  perform _audit('coupon.active', 'coupon', upper(trim(p_code)), p_reason, null, to_jsonb(p_active));
end $$;

create function admin_coupon_redemptions(p_code text) returns table (order_number text, customer text, discount_paise int, payment_status payment_status, redeemed_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require('coupons.manage');
  return query select o.order_number, c.full_name, o.discount_paise, o.payment_status, o.created_at
    from orders o join customers c on c.id = o.customer_id
   where o.coupon_code = upper(trim(p_code)) and o.payment_status in ('captured', 'refund_pending', 'refunded') order by o.created_at desc;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_list_coupons()', 'admin_create_coupons(text,int,text,text,int,int,int,timestamptz,timestamptz,boolean,text)',
    'admin_set_coupon_active(text,boolean,text)', 'admin_coupon_redemptions(text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
