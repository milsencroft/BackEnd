-- 0036: the browser reaches data only through the API, so signed-in users and visitors need no direct table access at all.
-- Row Level Security stays on as a second lock, but is no longer the only one. Everything the app does runs through
-- SECURITY DEFINER functions (owner privileges) or the service role, so none of it depends on the grants removed here.

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Future tables, sequences and functions start with no access for browser roles. Functions are granted explicitly.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;

-- Helpers and trigger functions that visitors never need to call directly.
revoke execute on function current_customer_id(), has_permission(text) from anon;
revoke execute on function forbid_mutation(), set_updated_at() from anon, authenticated;

-- _embed_url had a mutable search_path.
alter function _embed_url(text) set search_path = public;

-- Staff no longer write to storage from the browser: uploads use backend-signed URLs and deletes run on the backend.
drop policy if exists product_media_staff_insert on storage.objects;
drop policy if exists product_media_staff_update on storage.objects;
drop policy if exists product_media_staff_delete on storage.objects;
