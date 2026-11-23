create table customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete cascade,
  label text not null default 'Home',
  recipient text not null, phone text not null,
  line1 text not null, line2 text, city text not null, state text not null, pincode text not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);
create index on customer_addresses (customer_id);
create unique index customer_addresses_one_default on customer_addresses (customer_id) where is_default;
create table wishlist_items (
  customer_id uuid not null references customers(id) on delete cascade,
  product_code text not null references products(code) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (customer_id, product_code)
);
alter table customer_addresses enable row level security;
alter table wishlist_items enable row level security;
create policy addr_self_read on customer_addresses for select to authenticated
  using (customer_id in (select id from customers where auth_user_id = auth.uid()));
create policy wish_self_read on wishlist_items for select to authenticated
  using (customer_id in (select id from customers where auth_user_id = auth.uid()));
revoke all on customer_addresses, wishlist_items from anon, authenticated;
grant select on customer_addresses, wishlist_items to authenticated;

create function _my_customer() returns uuid language sql stable security definer set search_path = public as $$
  select id from customers where auth_user_id = auth.uid() and is_active $$;

create function my_save_address(p_id uuid, p_label text, p_recipient text, p_phone text, p_line1 text, p_line2 text,
  p_city text, p_state text, p_pincode text, p_default boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := _my_customer(); rid uuid;
begin
  if cid is null then raise exception 'forbidden'; end if;
  if coalesce(trim(p_recipient),'')='' or coalesce(trim(p_line1),'')='' or coalesce(trim(p_city),'')='' or coalesce(trim(p_state),'')=''
     or coalesce(p_pincode,'') !~ '^[1-9][0-9]{5}$' or coalesce(p_phone,'') !~ '^[+0-9 ]{10,15}$' then raise exception 'invalid_input'; end if;
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

create function my_delete_address(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare cid uuid := _my_customer();
begin
  if cid is null then raise exception 'forbidden'; end if;
  delete from customer_addresses where id = p_id and customer_id = cid;
  update customer_addresses set is_default = true where id = (select id from customer_addresses where customer_id = cid order by created_at limit 1)
    and not exists (select 1 from customer_addresses where customer_id = cid and is_default);
end $$;

create function my_toggle_wishlist(p_code text) returns boolean language plpgsql security definer set search_path = public as $$
declare cid uuid := _my_customer();
begin
  if cid is null then raise exception 'forbidden'; end if;
  if exists (select 1 from wishlist_items where customer_id = cid and product_code = p_code) then
    delete from wishlist_items where customer_id = cid and product_code = p_code; return false;
  end if;
  if not exists (select 1 from products where code = p_code and status = 'published') then raise exception 'not_found'; end if;
  if (select count(*) from wishlist_items where customer_id = cid) >= 100 then raise exception 'limit_reached'; end if;
  insert into wishlist_items (customer_id, product_code) values (cid, p_code); return true;
end $$;

do $$ declare f text; begin
  foreach f in array array['my_save_address(uuid,text,text,text,text,text,text,text,text,boolean)','my_delete_address(uuid)','my_toggle_wishlist(text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  revoke execute on function public._my_customer() from public, anon, authenticated;
end $$;
