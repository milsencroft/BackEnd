-- Run via execute_sql; rolled back. Cart add caps qty at 5, rejects bad SKUs, guest cart merges into customer cart.
do $$
declare g text := repeat('a',40); r text; v jsonb; sku1 text; cid uuid; k int;
begin
  select v2.sku into sku1 from variants v2 join products p on p.id=v2.product_id where v2.is_active and p.status='published' and not _variant_in_unreleased_launch(v2.id) limit 1;
  if sku1 is not null then
    r := cart_add(null, g, sku1, null, 2); if r <> 'ok' then raise exception 'add %', r; end if;
    r := cart_add(null, g, sku1, null, 9); v := cart_view(null,g);
    if (v->'lines'->0->>'qty')::int <> 5 then raise exception 'cap %', v; end if;
  end if;
  if cart_add(null, g, 'NOPE', null, 1) <> 'invalid_item' then raise exception 'bad sku'; end if;
  select id into cid from customers limit 1;
  perform cart_merge(cid, g);
  k := jsonb_array_length(cart_items_json(cid));
  if k <> (case when sku1 is null then 0 else 1 end) then raise exception 'merge %', k; end if;
  raise exception 'PASS_ROLLBACK';
end $$;
