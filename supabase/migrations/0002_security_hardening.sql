-- Migration 0002: security hardening from Supabase advisor findings
alter function public.set_updated_at() set search_path = public;
alter function public.forbid_mutation() set search_path = public;

-- Trigger function: never needs to be callable through the API.
revoke execute on function public.handle_new_auth_user() from public, anon, authenticated;
