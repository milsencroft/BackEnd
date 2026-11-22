-- Migration 0004: Super Admin bootstrap.
-- The listed email becomes Super Admin automatically on its first verified Google sign-in.
create table super_admin_bootstrap (
  email text primary key check (email = lower(email))
);
alter table super_admin_bootstrap enable row level security;

insert into super_admin_bootstrap (email) values ('milsencroft@gmail.com')
on conflict do nothing;

create or replace function handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_customer uuid;
  v_verified boolean;
begin
  insert into customers (auth_user_id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name')
  )
  on conflict (auth_user_id) do nothing
  returning id into v_customer;

  v_verified := new.email_confirmed_at is not null
             or coalesce((new.raw_user_meta_data->>'email_verified')::boolean, false);

  if v_customer is not null and v_verified and exists (
       select 1 from super_admin_bootstrap b where b.email = lower(new.email)) then
    insert into staff (customer_id, role) values (v_customer, 'super_admin')
    on conflict (customer_id) do nothing;
    insert into audit_log (actor_customer_id, action, entity_type, entity_id, reason)
    values (v_customer, 'staff.bootstrap_super_admin', 'customer', v_customer::text,
            'Matched super_admin_bootstrap on first verified sign-in');
  end if;

  return new;
end $$;
