import { Hono } from "hono";
import { cors } from "hono/cors";
import { DbError, type Deps } from "./types.ts";
import { verifyWebhookSignature } from "./signature.ts";
import { isCode, KNOWN_ERRORS, parseAddress, parseRetailItems } from "./validate.ts";

type BeginRow = { r_result: string; r_order_id: string | null; r_order_number: string | null; r_total_paise: number | null };
const BEGIN_STATUS: Record<string, number> = { not_found: 404, closed: 409, no_reservation: 409, invalid_item: 400 };

export function createApp(d: Deps) {
  const log = d.log ?? (() => {});
  const app = new Hono().basePath("/api");
  app.use("*", cors({ origin: d.allowedOrigin ?? "*", allowHeaders: ["authorization", "content-type"], allowMethods: ["GET", "POST", "OPTIONS"] }));

  app.onError((err, c) => {
    if (err instanceof DbError && err.message in KNOWN_ERRORS) return c.json({ error: err.message }, KNOWN_ERRORS[err.message] as 400);
    log("unhandled", { message: err.message });
    return c.json({ error: "internal_error" }, 500);
  });

  app.get("/health", (c) => c.json({ ok: true, payments_configured: d.razorpay !== null && d.webhookSecret !== null }));

  async function signedIn(authHeader: string | undefined) {
    const token = authHeader?.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
    if (!token) return null;
    const user = await d.store.authUser(token);
    if (!user) return null;
    const customerId = await d.store.customerIdForUser(user.id);
    return customerId ? { token, userId: user.id, customerId } : null;
  }

  /** Per-customer limit on checkout attempts. If the limiter itself fails, checkout stays available. */
  async function withinLimit(key: string, limit: number, windowSeconds: number) {
    try { return (await d.store.rpc<boolean>("rate_limit_hit", { p_key: key, p_limit: limit, p_window_seconds: windowSeconds })) !== false; }
    catch (e) { log("rate_limit_error", { message: (e as Error).message }); return true; }
  }

  /** Shared tail of both checkouts: create the Razorpay order for the amount THE DATABASE computed. */
  async function pay(row: BeginRow) {
    if (row.r_result !== "ok" || !row.r_order_id || !row.r_order_number || row.r_total_paise == null) {
      return { status: BEGIN_STATUS[row.r_result] ?? 400, body: { error: row.r_result } };
    }
    let rzp: { id: string };
    try {
      rzp = await d.razorpay!.createOrder({
        amountPaise: row.r_total_paise, receipt: row.r_order_number, notes: { order_id: row.r_order_id },
      });
      await d.store.rpc("attach_razorpay_order", { p_order: row.r_order_id, p_rzp_order: rzp.id });
    } catch (e) {
      log("payment_setup_failed", { order: row.r_order_number, message: (e as Error).message });
      await d.store.rpc("_cancel_unpaid_order", { p_order: row.r_order_id, p_reason: "payment setup failed" }).catch(() => {});
      return { status: 502, body: { error: "payment_unavailable" } };
    }
    return {
      status: 200,
      body: {
        order_id: row.r_order_id, order_number: row.r_order_number, amount_paise: row.r_total_paise, currency: "INR",
        razorpay_order_id: rzp.id, razorpay_key_id: d.keyId,
      },
    };
  }

  const notConfigured = (c: { json: (b: unknown, s: 503) => Response }) => c.json({ error: "payments_not_configured" }, 503);

  app.post("/checkout/launch", async (c) => {
    if (!d.razorpay) return notConfigured(c);
    const me = await signedIn(c.req.header("authorization"));
    if (!me) return c.json({ error: "unauthorized" }, 401);
    const body = await c.req.json().catch(() => null) as Record<string, unknown> | null;
    const address = parseAddress(body?.address);
    if (!body || !isCode(body.launch_code) || !isCode(body.sku) || !address) return c.json({ error: "invalid_request" }, 400);
    if (!(await withinLimit(`checkout:${me.customerId}`, 10, 60))) return c.json({ error: "rate_limited" }, 429);
    // Only identifiers and the address come from the browser. Price, tax and total are computed in the database.
    const rows = await d.store.rpc<BeginRow[]>("begin_launch_checkout", {
      p_customer: me.customerId, p_launch_code: body.launch_code, p_sku: body.sku, p_address: address,
    });
    const r = await pay(rows[0]);
    return c.json(r.body, r.status as 200);
  });

  app.post("/checkout/retail", async (c) => {
    if (!d.razorpay) return notConfigured(c);
    const me = await signedIn(c.req.header("authorization"));
    if (!me) return c.json({ error: "unauthorized" }, 401);
    const body = await c.req.json().catch(() => null) as Record<string, unknown> | null;
    const items = parseRetailItems(body?.items);
    const address = parseAddress(body?.address);
    const coupon = typeof body?.coupon === "string" ? body.coupon.trim().slice(0, 30) : null;
    if (!items || !address) return c.json({ error: "invalid_request" }, 400);
    if (!(await withinLimit(`checkout:${me.customerId}`, 10, 60))) return c.json({ error: "rate_limited" }, 429);
    const rows = await d.store.rpc<BeginRow[]>("begin_retail_checkout", {
      p_customer: me.customerId, p_items: items, p_address: address, p_coupon: coupon || null,
    });
    const r = await pay(rows[0]);
    return c.json(r.body, r.status as 200);
  });

  // ---- Razorpay webhook: signature -> idempotent SQL function -> refund fallback if the database asks for it ----
  app.post("/webhooks/razorpay", async (c) => {
    if (!d.webhookSecret || !d.razorpay) return notConfigured(c);
    const raw = await c.req.text();
    if (!(await verifyWebhookSignature(raw, c.req.header("x-razorpay-signature") ?? null, d.webhookSecret))) {
      return c.json({ error: "bad_signature" }, 401);
    }
    const eventId = c.req.header("x-razorpay-event-id");
    if (!eventId) return c.json({ error: "missing_event_id" }, 400);
    let evt: any;
    try { evt = JSON.parse(raw); } catch { return c.json({ error: "bad_json" }, 400); }
    const payload = evt?.payload ?? {};

    if (evt.event === "payment.captured") {
      const p = payload.payment?.entity;
      if (!p?.id || !p?.order_id || !Number.isInteger(p.amount)) return c.json({ error: "bad_payload" }, 400);
      // A non-INR capture can never match an order total, so it is reported as an amount mismatch.
      const amount = p.currency === "INR" ? p.amount : -1;
      const rows = await d.store.rpc<{ r_result: string; r_order_id: string | null; r_payment_id: string | null }[]>(
        "process_payment_captured",
        { p_event_id: eventId, p_rzp_order: p.order_id, p_rzp_payment: p.id, p_amount: amount, p_payload: evt },
      );
      const r = rows[0];
      if (r?.r_result === "refund_needed" && r.r_payment_id) {
        try {
          const refund = await d.razorpay.refundPayment(p.id, { amountPaise: p.amount, notes: { reason: "slot_or_stock_unavailable" } });
          await d.store.rpc("record_refund", { p_payment: r.r_payment_id, p_rzp_refund: refund.id, p_amount: p.amount, p_reason: "slot or stock unavailable after capture" });
        } catch (e) {
          // The event is already recorded, so a Razorpay retry would be ignored. Staff are alerted by the database
          // and can retry from the admin refund endpoint; the order stays in refund_pending.
          log("refund_fallback_failed", { payment: p.id, message: (e as Error).message });
        }
      }
      return c.json({ ok: true, result: r?.r_result });
    }

    if (evt.event === "payment.failed") {
      const p = payload.payment?.entity;
      if (!p?.order_id) return c.json({ ok: true, ignored: true });
      const res = await d.store.rpc("process_payment_failed", {
        p_event_id: eventId, p_rzp_order: p.order_id, p_reason: String(p.error_description ?? "payment failed").slice(0, 200), p_payload: evt,
      });
      return c.json({ ok: true, result: res });
    }

    if (evt.event === "refund.processed" || evt.event === "refund.failed") {
      const r = payload.refund?.entity;
      if (!r?.id || !r?.payment_id) return c.json({ error: "bad_payload" }, 400);
      const res = await d.store.rpc("process_refund_event", {
        p_event_id: eventId, p_rzp_refund: r.id, p_rzp_payment: r.payment_id, p_amount: r.amount ?? 0,
        p_status: evt.event === "refund.failed" ? "failed" : "processed", p_payload: evt,
      });
      return c.json({ ok: true, result: res });
    }
    return c.json({ ok: true, ignored: true });
  });

  // ---- Staff refund (also the retry path when the automatic fallback refund could not be sent) ----
  app.post("/admin/orders/:id/refund", async (c) => {
    if (!d.razorpay) return notConfigured(c);
    const me = await signedIn(c.req.header("authorization"));
    if (!me) return c.json({ error: "unauthorized" }, 401);
    if (!(await d.store.permissions(me.token)).includes("payments.refund")) return c.json({ error: "forbidden" }, 403);
    const body = await c.req.json().catch(() => null) as Record<string, unknown> | null;
    const reason = typeof body?.reason === "string" ? body.reason.trim().slice(0, 300) : "";
    if (!reason) return c.json({ error: "reason_required" }, 400);
    const orderId = c.req.param("id");
    if (!/^[0-9a-f-]{36}$/i.test(orderId)) return c.json({ error: "invalid_request" }, 400);
    const pay = await d.store.paymentForOrder(orderId);
    if (!pay || !pay.razorpay_payment_id || !["captured", "refund_pending"].includes(pay.status)) return c.json({ error: "not_refundable" }, 409);
    const prior = await d.store.refundsForPayment(pay.id);
    if (prior.some((r) => r.status === "pending" || r.status === "processed")) return c.json({ error: "refund_already_started" }, 409);
    const refund = await d.razorpay.refundPayment(pay.razorpay_payment_id, { amountPaise: pay.amount_paise, notes: { reason } });
    await d.store.rpc("record_refund", { p_payment: pay.id, p_rzp_refund: refund.id, p_amount: pay.amount_paise, p_reason: reason });
    await d.store.audit({ actor: me.customerId, action: "order.refund", entityType: "order", entityId: orderId, reason, after: { refund_id: refund.id, amount_paise: pay.amount_paise } });
    return c.json({ ok: true, razorpay_refund_id: refund.id });
  });

  return app;
}
