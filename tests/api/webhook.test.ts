import { describe, expect, it } from "vitest";
import { createHmac } from "node:crypto";
import { verifyWebhookSignature } from "../../supabase/functions/api/lib/signature.ts";
import { captured, setup, SECRET } from "./helpers.ts";

describe("webhook signature", () => {
  const body = '{"a":1}';
  const good = createHmac("sha256", SECRET).update(body).digest("hex");
  it("accepts the right signature", async () => expect(await verifyWebhookSignature(body, good, SECRET)).toBe(true));
  it("rejects a wrong secret, tampered body, missing or malformed signature", async () => {
    expect(await verifyWebhookSignature(body, createHmac("sha256", "other").update(body).digest("hex"), SECRET)).toBe(false);
    expect(await verifyWebhookSignature(body + " ", good, SECRET)).toBe(false);
    expect(await verifyWebhookSignature(body, null, SECRET)).toBe(false);
    expect(await verifyWebhookSignature(body, "abc", SECRET)).toBe(false);
  });
});

describe("POST /webhooks/razorpay", () => {
  it("rejects a bad signature and touches nothing", async () => {
    const t = setup();
    const res = await t.signed("/webhooks/razorpay", captured(), "evt_1", "wrong-secret");
    expect(res.status).toBe(401);
    expect(t.store.calls).toHaveLength(0);
  });

  it("requires the event id header", async () => {
    const t = setup();
    const raw = JSON.stringify(captured());
    const res = await t.call("/webhooks/razorpay", { method: "POST", headers: { "x-razorpay-signature": createHmac("sha256", SECRET).update(raw).digest("hex") }, body: raw });
    expect(res.status).toBe(400);
  });

  it("passes the captured amount and ids to the database, no refund when ok", async () => {
    const t = setup();
    t.store.results.process_payment_captured = [{ r_result: "ok", r_order_id: "o1", r_payment_id: "p1" }];
    const res = await t.signed("/webhooks/razorpay", captured(99900));
    expect(res.status).toBe(200);
    const [c] = t.store.called("process_payment_captured");
    expect(c.args).toMatchObject({ p_event_id: "evt_1", p_rzp_order: "order_RZP1", p_rzp_payment: "pay_1", p_amount: 99900 });
    expect(t.razorpay.refunds).toHaveLength(0);
  });

  it("duplicate events cause no refund and no second effect", async () => {
    const t = setup();
    t.store.results.process_payment_captured = [{ r_result: "duplicate", r_order_id: null, r_payment_id: null }];
    const res = await t.signed("/webhooks/razorpay", captured());
    expect(res.status).toBe(200);
    expect(t.razorpay.refunds).toHaveLength(0);
    expect(t.store.called("record_refund")).toHaveLength(0);
  });

  it("amount mismatch is acknowledged without a refund (staff review it)", async () => {
    const t = setup();
    t.store.results.process_payment_captured = [{ r_result: "amount_mismatch", r_order_id: "o1", r_payment_id: "p1" }];
    const res = await t.signed("/webhooks/razorpay", captured(1));
    expect(res.status).toBe(200);
    expect(t.razorpay.refunds).toHaveLength(0);
  });

  it("a non-INR capture is sent to the database as a mismatch (-1)", async () => {
    const t = setup();
    t.store.results.process_payment_captured = [{ r_result: "amount_mismatch", r_order_id: "o1", r_payment_id: "p1" }];
    await t.signed("/webhooks/razorpay", captured(99900, "USD"));
    expect(t.store.called("process_payment_captured")[0].args.p_amount).toBe(-1);
  });

  it("refund_needed triggers a full Razorpay refund and records it", async () => {
    const t = setup();
    t.store.results.process_payment_captured = [{ r_result: "refund_needed", r_order_id: "o1", r_payment_id: "p1" }];
    const res = await t.signed("/webhooks/razorpay", captured(99900));
    expect(res.status).toBe(200);
    expect(t.razorpay.refunds).toEqual([{ paymentId: "pay_1", amountPaise: 99900 }]);
    expect(t.store.called("record_refund")[0].args).toMatchObject({ p_payment: "p1", p_rzp_refund: "rfnd_1", p_amount: 99900 });
  });

  it("if the refund call fails the webhook still answers 200 (event is recorded) and nothing is recorded", async () => {
    const t = setup();
    t.razorpay.failRefund = true;
    t.store.results.process_payment_captured = [{ r_result: "refund_needed", r_order_id: "o1", r_payment_id: "p1" }];
    const res = await t.signed("/webhooks/razorpay", captured());
    expect(res.status).toBe(200);
    expect(t.store.called("record_refund")).toHaveLength(0);
  });

  it("a database failure returns 500 so Razorpay retries", async () => {
    const t = setup();
    t.store.failures.process_payment_captured = "deadlock detected";
    const res = await t.signed("/webhooks/razorpay", captured());
    expect(res.status).toBe(500);
  });

  it("payment.failed and refund events are routed to their handlers", async () => {
    const t = setup();
    await t.signed("/webhooks/razorpay", { event: "payment.failed", payload: { payment: { entity: { id: "pay_1", order_id: "order_RZP1", error_description: "card declined" } } } }, "evt_f");
    expect(t.store.called("process_payment_failed")[0].args).toMatchObject({ p_rzp_order: "order_RZP1", p_reason: "card declined" });
    await t.signed("/webhooks/razorpay", { event: "refund.processed", payload: { refund: { entity: { id: "rfnd_1", payment_id: "pay_1", amount: 99900 } } } }, "evt_r");
    expect(t.store.called("process_refund_event")[0].args).toMatchObject({ p_status: "processed", p_rzp_payment: "pay_1" });
    await t.signed("/webhooks/razorpay", { event: "refund.failed", payload: { refund: { entity: { id: "rfnd_2", payment_id: "pay_1", amount: 99900 } } } }, "evt_r2");
    expect(t.store.called("process_refund_event")[1].args.p_status).toBe("failed");
  });

  it("answers 503 before secrets are configured", async () => {
    const t = setup({ webhookSecret: null, razorpay: null });
    expect((await t.signed("/webhooks/razorpay", captured())).status).toBe(503);
  });
});
