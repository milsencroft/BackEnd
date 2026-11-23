-- Run via execute_sql; rolled back. Non-Google sign-ups are refused; a forged email_verified flag never grants Super Admin.
do $$
declare ok boolean := false;
begin
  begin
    insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data, aud, role)
    values (gen_random_uuid(), 'attacker@example.com', '{"provider":"email"}', '{"email_verified":true}', 'authenticated', 'authenticated');
  exception when others then ok := sqlerrm like '%google_sign_in_only%'; end;
  if not ok then raise exception 'password signup was allowed'; end if;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data, aud, role)
  values (gen_random_uuid(), 'newperson@example.com', '{"provider":"google"}', '{}', 'authenticated', 'authenticated');
  if not exists (select 1 from customers where email = 'newperson@example.com') then raise exception 'google signup not created'; end if;
  raise exception 'PASS_ROLLBACK';
end $$;
