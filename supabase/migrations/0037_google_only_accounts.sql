-- 0037: accounts exist only through Google. The previous check trusted raw_user_meta_data, which the person signing up controls,
-- so a password sign-up could claim to be "email_verified". Now: provider must be google, and only the provider's own
-- confirmation (email_confirmed_at) counts. Password / magic-link / phone / anonymous sign-ups are refused at the database,
-- whatever the Auth settings say.
create or replace function handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_customer uuid;
begin
  if coalesce(new.raw_app_meta_data->>'provider', '') <> 'google' or coalesce(new.is_anonymous, false) then
    raise exception 'google_sign_in_only';
  end if;

  insert into customers (auth_user_id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'))
  on conflict (auth_user_id) do nothing
  returning id into v_customer;

  if v_customer is not null and new.email_confirmed_at is not null and exists (
       select 1 from super_admin_bootstrap b where b.email = lower(new.email)) then
    insert into staff (customer_id, role) values (v_customer, 'super_admin') on conflict (customer_id) do nothing;
    insert into audit_log (actor_customer_id, action, entity_type, entity_id, reason)
    values (v_customer, 'staff.bootstrap_super_admin', 'customer', v_customer::text, 'Matched super_admin_bootstrap on first verified Google sign-in');
  end if;
  return new;
end $$;
