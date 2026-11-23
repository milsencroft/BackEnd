-- Run via execute_sql; rolled back. Cart add/set never exceeds available stock; out of stock refused; shop reports max_qty.
do $$
declare g text := repeat('b',40); r text; v jsonb; vid uuid; s text := 'MC-KER-001-50ML'; old int;
begin
  select id, stock_on_hand into vid, old from variants where sku = s;
  update variants set stock_on_hand = stock_reserved + 3 where id = vid;
  r := cart_add(null, g, s, null, 2); if r <> 'ok' then raise exception 'a %', r; end if;
  r := cart_add(null, g, s, null, 4); if r <> 'capped' then raise exception 'b %', r; end if;
  v := cart_view(null, g); if (v->'lines'->0->>'qty')::int <> 3 or (v->'lines'->0->>'max_qty')::int <> 3 then raise exception 'c %', v; end if;
  update variants set stock_on_hand = stock_reserved where id = vid;
  if cart_add(null, g, s, null, 1) <> 'out_of_stock' then raise exception 'd'; end if;
  if (select max_qty from shop_catalogue() where sku = s) <> 0 then raise exception 'e'; end if;
  raise exception 'PASS_ROLLBACK';
end $$;
