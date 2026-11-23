-- Run via execute_sql as Super Admin; rolled back. Set/add stock, reserved floor, reason required, storefront reflects it.
do $$
declare vid uuid; r record; sku1 text := 'MC-KER-001-50ML';
begin
  perform set_config('request.jwt.claims','{"sub":"e657ce70-0442-451a-b394-68dc59cb6dcb","role":"authenticated"}',true);
  set local role authenticated;
  select variant_id into vid from admin_inventory_list() where sku = sku1;
  perform admin_set_stock(vid, 7, 'test');
  if (select on_hand from admin_inventory_list() where sku = sku1) <> 7 then raise exception 'set'; end if;
  perform admin_adjust_stock(vid, 5, 'test add');
  if (select on_hand from admin_inventory_list() where sku = sku1) <> 12 then raise exception 'add'; end if;
  begin perform admin_set_stock(vid, 3, ''); raise exception 'no reason accepted'; exception when others then if sqlerrm = 'no reason accepted' then raise; end if; end;
  begin perform admin_set_stock(vid, -1, 'x'); raise exception 'negative accepted'; exception when others then if sqlerrm = 'negative accepted' then raise; end if; end;
  raise exception 'PASS_ROLLBACK';
end $$;
