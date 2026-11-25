import { createHmac } from "node:crypto";
import { createApp } from "../../supabase/functions/api/lib/app.ts";
import { DbError, type Deps, type PaymentRow, type RazorpayClient, type Store } from "../../supabase/functions/api/lib/types.ts";

export const SECRET = "whsec_test";
export const ADDRESS = { name: "A Buyer", phone: "9876543210", line1: "1 MG Road", city: "Kochi", state_code: "32", pincode: "682001" };

export class FakeStore implements Store {
  calls: { fn: string; args: Record<string, unknown> }[] = [];
  results: Record<string, unknown> = {};
  failures: Record<string, string> = {};
  perms: string[] = [];
  payment: PaymentRow | null = null;
  refunds: { status: string; amount_paise: number }[] = [];
  audits: unknown[] = [];
  async authUser(t: string) { return t === "good" ? { id: "user-1" } : null; }
  async customerIdForUser() { return "cust-1"; }
  async permissions() { return this.perms; }
  async rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
    this.calls.push({ fn, args });
    if (this.failures[fn]) throw new DbError(this.failures[fn]);
    return (this.results[fn] ?? []) as T;
  }
  as: { token: string | null; fn: string; args: Record<string, unknown> }[] = [];
  removed: string[][] = [];
  async callAs<T>(token: string | null, fn: string, args: Record<string, unknown>): Promise<T> {
    this.as.push({ token, fn, args });
    if (this.failures[fn]) throw new DbError(this.failures[fn]);
    return (this.results[fn] ?? null) as T;
  }
  async signedUpload(path: string) { return { signed_url: "https://signed.example/x", token: "t", path }; }
  async removeMedia(paths: string[]) { this.removed.push(paths); }
  async paymentForOrder() { return this.payment; }
  async refundsForPayment() { return this.refunds; }
  async audit(e: unknown) { this.audits.push(e); }
  called(fn: string) { return this.calls.filter((c) => c.fn === fn); }
}

export class FakeRazorpay implements RazorpayClient {
  orders: unknown[] = []; refunds: { paymentId: string; amountPaise: number }[] = [];
  failOrder = false; failRefund = false; refundError: string | null = null;
  async createOrder(i: { amountPaise: number; receipt: string }) {
    if (this.failOrder) throw new Error("razorpay down");
    this.orders.push(i); return { id: "order_RZP1" };
  }
  async refundPayment(paymentId: string, i: { amountPaise: number }) {
    if (this.refundError) throw new Error(this.refundError);
    if (this.failRefund) throw new Error("razorpay down");
    this.refunds.push({ paymentId, amountPaise: i.amountPaise }); return { id: "rfnd_1" };
  }
}

export function setup(over: Partial<Deps> = {}) {
  const store = new FakeStore(); const razorpay = new FakeRazorpay();
  const app = createApp({ store, razorpay, keyId: "rzp_test_key", webhookSecret: SECRET, ...over });
  const call = (path: string, init: RequestInit = {}) => app.request(`http://x/api${path}`, init);
  const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
    call(path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
  const signed = (path: string, payload: unknown, eventId = "evt_1", secret = SECRET) => {
    const raw = JSON.stringify(payload);
    return call(path, { method: "POST", headers: { "x-razorpay-signature": createHmac("sha256", secret).update(raw).digest("hex"), "x-razorpay-event-id": eventId }, body: raw });
  };
  return { store, razorpay, app, call, post, signed };
}

export const captured = (amount = 99900, currency = "INR") => ({
  event: "payment.captured", payload: { payment: { entity: { id: "pay_1", order_id: "order_RZP1", amount, currency, status: "captured" } } },
});
