-- Follow-up to 0036 (already applied live): helper functions are not callable by visitors or by the browser roles directly.
revoke execute on function current_customer_id(), has_permission(text) from public, anon;
grant execute on function current_customer_id(), has_permission(text) to authenticated;
revoke execute on function forbid_mutation(), set_updated_at() from public;
