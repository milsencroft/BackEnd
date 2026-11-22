-- Migration 0014: scheduled jobs. Expiry of stale unpaid orders and slot holds, every 2 minutes.
create extension if not exists pg_cron;
select cron.schedule('expire-stale-orders', '*/2 * * * *', $$select public.expire_stale_orders()$$);
