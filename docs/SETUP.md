# Backend setup

## Supabase
- Project: `milsen-croft` (ref `gnnbgewcmheuhdlxhyue`, Mumbai ap-south-1).
- Migrations live in `supabase/migrations/` and are applied in order (0001 to 0014).
  Next migration number: 0015.
- Keep this folder and the database in sync: every schema change is a new numbered file.

## Google sign-in
- Google Cloud OAuth client (Web). Authorized redirect URI:
  `https://gnnbgewcmheuhdlxhyue.supabase.co/auth/v1/callback`
- Client ID and secret are entered in Supabase, Authentication, Providers, Google. Not stored in this repo.

## Super Admin
- Emails in the `super_admin_bootstrap` table become Super Admin on their first verified
  Google sign-in (migration 0004). Add more with an insert (lowercase email).

## Environment
- Copy `.env.example` to `.env.local` and fill in values. Never commit `.env.local`.

## Launch rules (summary)
- One combined 100-slot pool per launch, one slot per customer.
- Slot is reserved BEFORE payment (`reserve_launch_slot`); `confirm_launch_slot` is called only
  from the verified Razorpay webhook. A `full` or `launch_unavailable` result after capture
  triggers the automatic refund fallback.

## API (Supabase Edge Function `api`)
- Code: `supabase/functions/api` (Hono). Deployed with `verify_jwt` off because the function authenticates
  itself (Supabase JWT for customers/staff, HMAC signature for Razorpay webhooks).
- Base URL: `https://gnnbgewcmheuhdlxhyue.supabase.co/functions/v1/api`
- Routes: `GET /health`, `POST /checkout/launch`, `POST /checkout/retail`, `POST /webhooks/razorpay`,
  `POST /admin/orders/:id/refund`.
- Secrets (Supabase Dashboard > Edge Functions > Secrets): `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`,
  `RAZORPAY_WEBHOOK_SECRET`, optional `ALLOWED_ORIGIN`. Without them payment routes answer 503.
- Razorpay webhook: URL `.../functions/v1/api/webhooks/razorpay`; events `payment.captured`,
  `payment.failed`, `refund.processed`, `refund.failed`.
- Tests: `npm test` (vitest, fakes for the database and Razorpay) and `npm run typecheck`.
- If a secret is ever pasted into the repo or chat, regenerate it in Razorpay and update the Supabase secret.

## Scheduled jobs
- `expire-stale-orders` (pg_cron, every 2 minutes) cancels unpaid orders after 45 minutes and releases stock.

## Pending list (deliberately left for later)
- **Courier API integration**: live shipment status from a tracking service (for example Shiprocket, Delhivery or a tracking aggregator), so order pages update on their own. Needs an account with that service and its credentials. Today staff set the status by hand and tracking links come from the Couriers page.
- **Domain, live Razorpay keys and the end-to-end payment check** (done last, on purpose).
- Rotate the Razorpay test key that was committed earlier, then update the Supabase secrets and the Vercel public key.

## Not built yet
- Notification sender worker (email needs a verified domain/provider; WhatsApp stays manual-approval). The queue, retry/backoff and admin screen exist; `outbox_claim`, `outbox_mark_sent`, `outbox_mark_failed` and `outbox_mark_delivered` (service role only) are ready for the worker to call.
- Automated SQL scenario tests (see `tests/sql/README.md`).
