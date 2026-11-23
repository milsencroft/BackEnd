-- Length caps on free-text customer input, enforced in the database (the API and browser are not trusted).
create or replace function my_save_address(p_id uuid, p_label text, p_recipient text, p_phone text, p_line1 text, p_line2 text, p_city text, p_state text, p_pincode text, p_default boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid := _my_customer(); rid uuid;
begin
  if cid is null then raise exception 'forbidden'; end if;
  if coalesce(trim(p_recipient),'')='' or coalesce(trim(p_line1),'')='' or coalesce(trim(p_city),'')='' or coalesce(trim(p_state),'')=''
     or coalesce(p_pincode,'') !~ '^[1-9][0-9]{5}$' or coalesce(p_phone,'') !~ '^[+0-9 ]{10,15}$' then raise exception 'invalid_input'; end if;
  if length(coalesce(p_label,'')) > 40 or length(p_recipient) > 100 or length(p_line1) > 200 or length(coalesce(p_line2,'')) > 200
     or length(p_city) > 80 or length(p_state) > 80 then raise exception 'invalid_input'; end if;
  if p_id is null and (select count(*) from customer_addresses where customer_id = cid) >= 10 then raise exception 'limit_reached'; end if;
  if coalesce(p_default, false) then update customer_addresses set is_default = false where customer_id = cid; end if;
  if p_id is null then
    insert into customer_addresses (customer_id,label,recipient,phone,line1,line2,city,state,pincode,is_default)
    values (cid, coalesce(nullif(trim(p_label),''),'Home'), trim(p_recipient), trim(p_phone), trim(p_line1), nullif(trim(coalesce(p_line2,'')),''), trim(p_city), trim(p_state), p_pincode,
      coalesce(p_default, false) or not exists (select 1 from customer_addresses where customer_id = cid)) returning id into rid;
  else
    update customer_addresses set label=coalesce(nullif(trim(p_label),''),'Home'), recipient=trim(p_recipient), phone=trim(p_phone), line1=trim(p_line1),
      line2=nullif(trim(coalesce(p_line2,'')),''), city=trim(p_city), state=trim(p_state), pincode=p_pincode, is_default=coalesce(p_default,is_default)
     where id = p_id and customer_id = cid returning id into rid;
    if rid is null then raise exception 'not_found'; end if;
  end if;
  return rid;
end $$;

create or replace function update_my_profile(p_name text, p_phone text, p_whatsapp boolean)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid := current_customer_id(); cur boolean;
begin
  if c is null then raise exception 'not_signed_in'; end if;
  if coalesce(p_phone, '') <> '' and p_phone !~ '^[6-9][0-9]{9}$' then raise exception 'invalid_phone'; end if;
  if length(coalesce(p_name, '')) > 100 then raise exception 'invalid_input'; end if;
  select whatsapp_consent into cur from customers where id = c;
  update customers set full_name = coalesce(nullif(trim(p_name), ''), full_name), phone = nullif(trim(p_phone), ''),
         whatsapp_consent = coalesce(p_whatsapp, whatsapp_consent),
         whatsapp_consent_at = case when p_whatsapp is true and not cur then now() when p_whatsapp is false then null else whatsapp_consent_at end,
         whatsapp_consent_source = case when p_whatsapp is true and not cur then 'account_page' else whatsapp_consent_source end
   where id = c;
end $$;
