-- The cart preview also returns the amount after offers, so no browser ever does price arithmetic.
create or replace function cart_offer_preview(p_customer uuid, p_guest text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; lines jsonb; r record;
begin
  v := cart_view(p_customer, p_guest);
  select coalesce(jsonb_agg(jsonb_build_object('product_id', va.product_id, 'qty', (x->>'qty')::int, 'unit', (x->>'unit_paise')::int)), '[]') into lines
    from jsonb_array_elements(v->'lines') x join variants va on va.sku = x->>'sku' where (x->>'ok')::boolean;
  select * into r from offer_discount(p_customer, lines);
  return jsonb_build_object('offer_discount_paise', r.r_discount, 'offer_labels', to_jsonb(r.r_labels), 'offers_block_coupon', r.r_blocks,
    'after_offers_paise', greatest(0, coalesce((v->>'subtotal_paise')::int, 0) - r.r_discount));
end $$;
