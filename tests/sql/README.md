# SQL scenario tests

Migrations 0011–0014 were verified against the live project with rolled-back DO blocks.
Scenarios covered (re-run them after any change to those functions):

- Launch happy path: reserve -> checkout -> captured webhook -> allocation 1, membership granted, stock committed.
- Duplicate event id / duplicate payment id: no second effect.
- Amount mismatch: flagged, no confirmation.
- Launch closed after payment: `refund_needed`, stock released (migration 0012).
- Launch-only products blocked in retail until the launch is released (`launch_only`).
- Retail and duo-pack totals (299800 / 199900 paise).
- Stale unpaid order expiry releases held stock.
- Admin RBAC: order_manager cannot change launches/settings; fulfilment transitions enforced; tracking required to ship; paid cancel requires refund; self-revoke blocked.
- GST inclusive tax on 99900 paise = 15239 (CGST 7619 / SGST 7620).

TODO: convert these into committed, automated pgTAP/psql scripts (needs a disposable database; not available in CI yet).

Added with migrations 0015-0018:
- admin_set_fulfilment has a single overload, the body contains the full transition table, and calling it as the Super Admin with an unknown order returns `not_found` (checked in a rolled-back DO block).
- TODO: exercise every transition (shipped -> in_transit -> out_for_delivery -> delivered -> return_requested -> returned, delivery_failed paths) with a captured test order.

Migration 0019 (verified in a rolled-back block as Super Admin): order number matches `MC-ORD-YYYY-NNNNN`; add note -> detail shows the note and customer; search by order number and by phone finds the order; payment filter excludes it; `order_notes` is not readable directly; a non-staff user gets `forbidden`.

Migration 0020 (verified in rolled-back blocks as Super Admin): create and edit a region (new regions start as draft), create a product (draft), catalogue listing shows both, launch creation defaults capacity to 100 and rejects duplicate codes, invalid region code and missing reason are rejected, an active launch cannot have its variants edited (`launch_locked`), setting variants replaces the previous set, and a zero price is rejected.

Migration 0021 (rolled-back block as Super Admin): custom code created; 25 random prefixed codes created and all single-use; duplicate code, percent over 100 and missing reason rejected; deactivating a coupon shows in the list; redemptions empty for an unused coupon.
Not yet implemented (needs a checkout change, after the payment test): per-customer limit, maximum discount, Society-tier/product/collection applicability, stacking rules.

Migration 0022 (rolled-back block as a customer): first address becomes default; bad pincode rejected; wishlist toggle adds then removes; unknown or unpublished product rejected; address delete works.

Migration 0023 (rolled-back blocks, cap of tier 2 set to 1 for the test): trigger promotes a returning member one tier and renumbers (MS-TB-T2-001); a full next tier queues the member and keeps the current tier; cycle rejects active and cancelled launches, a missing reason and a second run; one missed launch only counts; two in a row end Tier 1 membership and add the customer to the Tier 1 re-entry list; a Tier 2 member moves down to Tier 1 and the queued member advances; a lapsed customer buying again is waitlisted, not re-admitted; admin admit issues a new number; history keeps old numbers; grant_membership still grants and returns existing.

Migration 0024 (rolled-back block as Super Admin, fake storage object): alt text under 3 characters, a bad path and a missing file are rejected; register, assign to a product, unknown media rejected; changing alt text propagates to the product's images; a media file in use cannot be deleted; delete returns the storage path for removal.

Migration 0025 (rolled-back block as Super Admin, fake paid launch order in processing): checklist lists the order line, seal, invoice and Society items; marking Packed is blocked until all are ticked; unticking one blocks again; an unknown item is rejected; once Packed the checklist is locked.
