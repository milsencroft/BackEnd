import { describe, expect, it } from "vitest";
import { ADDRESS, setup } from "./helpers.ts";

const auth = { authorization: "Bearer good" };
const ok = [{ r_result: "ok", r_order_id: "o1", r_order_number: "MC-1001", r_total_paise: 99900 }];

describe("POST /checkout/launch", () => {
  it("requires sign-in", async () => {
    const t = setup();
    expect((await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS })).status).toBe(401);
    expect((await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS }, { authorization: "Bearer bad" })).status).toBe(401);
  });

  it("rejects bad input before touching the database", async () => {
    const t = setup();
    expect((await t.post("/checkout/launch", { launch_code: "KJ", sku: "X" }, auth)).status).toBe(400);
    expect((await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: { ...ADDRESS, phone: "123" } }, auth)).status).toBe(400);
    expect((await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: { ...ADDRESS, pincode: "000000" } }, auth)).status).toBe(400);
    expect(t.store.calls).toHaveLength(0);
  });

  it("charges the amount the database computed and ignores any price sent by the browser", async () => {
    const t = setup();
    t.store.results.begin_launch_checkout = ok;
    const res = await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS, price: 1, amount_paise: 1, total: 1 }, auth);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ order_number: "MC-1001", amount_paise: 99900, razorpay_order_id: "order_RZP1", razorpay_key_id: "rzp_test_key", currency: "INR" });
    expect(t.razorpay.orders).toEqual([{ amountPaise: 99900, receipt: "MC-1001", notes: { order_id: "o1" } }]);
    expect(t.store.called("begin_launch_checkout")[0].args).toEqual({ p_customer: "cust-1", p_launch_code: "KJ", p_sku: "MC-KER-001-50ML", p_address: ADDRESS });
    expect(t.store.called("attach_razorpay_order")[0].args).toEqual({ p_order: "o1", p_rzp_order: "order_RZP1" });
  });

  it.each([["closed", 409], ["no_reservation", 409], ["not_found", 404], ["invalid_item", 400]])("maps %s to %i and never opens payment", async (result, status) => {
    const t = setup();
    t.store.results.begin_launch_checkout = [{ r_result: result, r_order_id: null, r_order_number: null, r_total_paise: null }];
    const res = await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS }, auth);
    expect(res.status).toBe(status);
    expect(t.razorpay.orders).toHaveLength(0);
  });

  it("cancels the order (releasing stock) when Razorpay is down", async () => {
    const t = setup();
    t.store.results.begin_launch_checkout = ok; t.razorpay.failOrder = true;
    const res = await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS }, auth);
    expect(res.status).toBe(502);
    expect(t.store.called("_cancel_unpaid_order")[0].args.p_order).toBe("o1");
  });

  it("answers 503 until Razorpay secrets are set", async () => {
    const t = setup({ razorpay: null });
    expect((await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS }, auth)).status).toBe(503);
  });
});

describe("POST /checkout/retail", () => {
  const cart = [{ sku: "MC-KER-001-50ML", qty: 1 }];
  it("buys what the server cart holds and ignores any items sent by the browser", async () => {
    const t = setup();
    t.store.results.cart_items_json = [{ bundle: "MC-DUO-001", qty: 1 }];
    t.store.results.begin_retail_checkout = [{ r_result: "ok", r_order_id: "o2", r_order_number: "MC-1002", r_total_paise: 199900 }];
    const res = await t.post("/checkout/retail", { items: [{ sku: "MC-KER-001-50ML", qty: 5 }], address: ADDRESS }, auth);
    expect(res.status).toBe(200);
    expect(t.razorpay.orders).toEqual([{ amountPaise: 199900, receipt: "MC-1002", notes: { order_id: "o2" } }]);
    expect(t.store.called("begin_retail_checkout")[0].args.p_items).toEqual([{ bundle: "MC-DUO-001", qty: 1 }]);
  });

  it("refuses an empty cart and a bad address without touching payment", async () => {
    const t = setup();
    t.store.results.cart_items_json = [];
    expect((await t.post("/checkout/retail", { address: ADDRESS }, auth)).status).toBe(400);
    t.store.results.cart_items_json = cart;
    expect((await t.post("/checkout/retail", { address: { name: "x" } }, auth)).status).toBe(400);
    expect(t.store.called("begin_retail_checkout")).toHaveLength(0);
  });

  it("maps database refusals (launch-only product, stock, coupon) to clear errors", async () => {
    const t = setup(); t.store.results.cart_items_json = cart;
    const body = { address: ADDRESS, coupon: "X" };
    t.store.failures.begin_retail_checkout = "launch_only";
    let res = await t.post("/checkout/retail", body, auth);
    expect(res.status).toBe(409); expect(await res.json()).toEqual({ error: "launch_only" });
    t.store.failures.begin_retail_checkout = "out_of_stock";
    expect((await t.post("/checkout/retail", body, auth)).status).toBe(409);
    t.store.failures.begin_retail_checkout = "invalid_coupon";
    expect((await t.post("/checkout/retail", body, auth)).status).toBe(400);
  });
});

describe("POST /admin/orders/:id/refund", () => {
  const id = "11111111-2222-3333-4444-555555555555";
  it("requires the payments.refund permission", async () => {
    const t = setup(); t.store.perms = ["orders.view"];
    expect((await t.post(`/admin/orders/${id}/refund`, { reason: "x" })).status).toBe(401);
    expect((await t.post(`/admin/orders/${id}/refund`, { reason: "x" }, auth)).status).toBe(403);
  });
  it("needs a reason, a refundable payment, and refuses a second refund", async () => {
    const t = setup(); t.store.perms = ["payments.refund"];
    expect((await t.post(`/admin/orders/${id}/refund`, {}, auth)).status).toBe(400);
    expect((await t.post(`/admin/orders/${id}/refund`, { reason: "damaged" }, auth)).status).toBe(409);
    t.store.payment = { id: "p1", razorpay_payment_id: "pay_1", amount_paise: 99900, status: "captured" };
    t.store.refunds = [{ status: "pending", amount_paise: 99900 }];
    expect((await t.post(`/admin/orders/${id}/refund`, { reason: "damaged" }, auth)).status).toBe(409);
    expect(t.razorpay.refunds).toHaveLength(0);
  });
  it("explains a refund Razorpay already holds, and a Razorpay outage, instead of a generic 500", async () => {
    const t = setup(); t.store.perms = ["payments.refund"];
    t.store.payment = { id: "p1", razorpay_payment_id: "pay_1", amount_paise: 99900, status: "captured" };
    t.razorpay.refundError = "razorpay 400: The payment has been fully refunded already";
    let res = await t.post(`/admin/orders/${id}/refund`, { reason: "x" }, auth);
    expect(res.status).toBe(409); expect(await res.json()).toEqual({ error: "already_refunded" });
    t.razorpay.refundError = "razorpay 500: down";
    res = await t.post(`/admin/orders/${id}/refund`, { reason: "x" }, auth);
    expect(res.status).toBe(502); expect(await res.json()).toEqual({ error: "refund_failed" });
    expect(t.store.called("record_refund")).toHaveLength(0);
  });
  it("refunds in full, records it and writes an audit entry with the actor and reason", async () => {
    const t = setup(); t.store.perms = ["payments.refund"];
    t.store.payment = { id: "p1", razorpay_payment_id: "pay_1", amount_paise: 99900, status: "refund_pending" };
    const res = await t.post(`/admin/orders/${id}/refund`, { reason: "customer request" }, auth);
    expect(res.status).toBe(200);
    expect(t.razorpay.refunds).toEqual([{ paymentId: "pay_1", amountPaise: 99900 }]);
    expect(t.store.called("record_refund")).toHaveLength(1);
    expect(t.store.audits[0]).toMatchObject({ actor: "cust-1", action: "order.refund", entityId: id, reason: "customer request" });
  });
});

describe("misc", () => {
  it("health is public and reports whether payments are configured", async () => {
    expect(await (await setup().call("/health")).json()).toEqual({ ok: true, payments_configured: true });
    expect(await (await setup({ razorpay: null }).call("/health")).json()).toEqual({ ok: true, payments_configured: false });
  });
  it("unexpected errors never leak details", async () => {
    const t = setup(); t.store.failures.begin_launch_checkout = "relation \"secret_table\" does not exist";
    const res = await t.post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS }, { authorization: "Bearer good" });
    expect(res.status).toBe(500); expect(await res.json()).toEqual({ error: "internal_error" });
  });
});

describe("rate limiting", () => {
  it("answers 429 when the database says the customer is over the limit, and never reaches payment", async () => {
    const { store, razorpay, post } = setup();
    store.results["rate_limit_hit"] = false;
    const r = await post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS }, { authorization: "Bearer good" });
    expect(r.status).toBe(429);
    expect(razorpay.orders).toHaveLength(0);
    expect(store.called("begin_launch_checkout")).toHaveLength(0);
  });
  it("keeps checkout available if the limiter errors", async () => {
    const { store, post } = setup();
    store.failures["rate_limit_hit"] = "boom";
    store.results["begin_launch_checkout"] = [{ r_result: "closed", r_order_id: null, r_order_number: null, r_total_paise: null }];
    const r = await post("/checkout/launch", { launch_code: "KJ", sku: "MC-KER-001-50ML", address: ADDRESS }, { authorization: "Bearer good" });
    expect(r.status).toBe(409);
    expect(store.called("begin_launch_checkout")).toHaveLength(1);
  });
});
