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
