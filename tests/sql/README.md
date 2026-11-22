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
