# Backend setup

## Supabase
- Project: `milsen-croft` (ref `gnnbgewcmheuhdlxhyue`, Mumbai ap-south-1).
- Migrations live in `supabase/migrations/` and are applied in order (0001 to 0009).
  Next migration number: 0010.
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
