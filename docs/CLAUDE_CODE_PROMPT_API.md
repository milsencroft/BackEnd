# Prompt for Claude Code: backend API service (Phase 3/4 core)

Paste this into Claude Code opened in the BackEnd folder. Read CLAUDE.md and docs/PHASES.md first.

---

The Supabase database is ALREADY built and migrated (project ref gnnbgewcmheuhdlxhyue, migrations 0001-0009
in supabase/migrations/). Do NOT re-run or edit those migrations. Any schema change is a new numbered file.

Build the TypeScript (Node) API service in this repo. Use env vars from .env.example only; never hard-code secrets.

## 1. Scaffold
- Node + TypeScript, a small HTTP framework (Fastify or Express), zod validation, vitest for tests.
- Supabase service-role client (server only). Structured logging. Health endpoint.
- Auth middleware: verify the Supabase JWT from the Authorization header, map to customers.id,
  load staff role. Enforce permissions in the API (has_permission semantics) AND rely on RLS.

## 2. Launch and checkout endpoints
- GET  /launches/:code            public state: remaining = capacity - allocated - active reservations.
- POST /launches/:code/reserve    calls rpc reserve_launch_slot. Return reservation id + expires_at, or full/closed.
- POST /checkout/launch           requires an active reservation. Recompute prices SERVER-SIDE from
                                  launch_variants.launch_price_paise (Rs 999). One bottle per slot.
                                  Compute GST with rpc calc_gst. Create the order (launch_preorder), reserve_stock,
                                  create the Razorpay order (expiry slightly shorter than the reservation), insert payments row.
- POST /checkout/retail           regular orders at variants.price_paise (Rs 1499) and the duo bundle (Rs 1999).
                                  Launch variants are NEVER purchasable here while the launch is active.
- Never trust prices, totals, discounts or stock from the browser.

## 3. Razorpay webhook  POST /webhooks/razorpay
- Verify the signature with RAZORPAY_WEBHOOK_SECRET. Insert event_id into razorpay_events first
  (primary key = idempotency). If it already exists, return 200 and do nothing.
- Verify the captured amount equals orders.total_paise.
- payment.captured on a launch order: rpc confirm_launch_slot, then grant_membership (tier 1), commit_stock,
  set payment_status and write order_status_history. 
- If confirm_launch_slot returns 'full' or 'launch_unavailable': create an automatic Razorpay refund,
  insert a refunds row, set payment_status refund_pending, enqueue a customer notification. This must be rare.
- payment.failed: release_stock, release the reservation, record the failure.
- All steps inside one transaction where possible; never process the same event twice.

## 4. Jobs
- Reservation expiry every minute: rpc release_expired_reservations, and release_stock for expired holds.
- Notification outbox worker: pick pending rows by next_attempt_at, retry with exponential backoff,
  never block or duplicate an order. WhatsApp starts in manual-approval mode. Only a delivery receipt sets delivered_at.

## 5. Admin endpoints (permission-gated, every change writes audit_log with actor and reason)
- Launch: create/edit/publish/pause/cancel/close. Capacity change and any override REQUIRE a reason.
- Catalogue: regions, products, variants, media, pricing, inventory adjust (inventory_movements).
- Orders: list/detail, status transitions for payment and fulfilment as two separate state machines.
- Settings: GST toggle (store_settings 'gst'): Super Admin only.
- Staff: grant/revoke roles (Super Admin only). Society tier caps: Super Admin only.

## 6. Tests (required before you stop)
- Concurrency: 150 parallel reserve+confirm calls against a capacity-100 launch must give exactly 100 allocations.
- Webhook: bad signature rejected; duplicate event processed once; amount mismatch rejected;
  full-after-capture triggers the refund path.
- Stock: parallel reservations never oversell the 500 units per fragrance.
- GST: off by default; inclusive vs exclusive; CGST+SGST in-state (state code 32), IGST out of state.

## Working rules
- Money is integer paise. Small commits, one branch (phase-3-4-api). Stop and ask if anything is missing.
- Do not invent tracking numbers, URLs or payment data.
