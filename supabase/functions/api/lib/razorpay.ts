import type { RazorpayClient } from "./types.ts";

export function createRazorpayClient(keyId: string, keySecret: string, f: typeof fetch = fetch): RazorpayClient {
  const authorization = "Basic " + btoa(`${keyId}:${keySecret}`);
  async function post(path: string, body: unknown): Promise<{ id: string }> {
    const res = await f(`https://api.razorpay.com/v1${path}`, {
      method: "POST",
      headers: { authorization, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`razorpay ${res.status}: ${json?.error?.description ?? "request failed"}`);
    return json as { id: string };
  }
  return {
    // Amounts are integer paise, exactly as Razorpay expects.
    createOrder: ({ amountPaise, receipt, notes }) =>
      post("/orders", { amount: amountPaise, currency: "INR", receipt, notes: notes ?? {} }),
    refundPayment: (paymentId, { amountPaise, notes }) =>
      post(`/payments/${encodeURIComponent(paymentId)}/refund`, { amount: amountPaise, notes: notes ?? {} }),
  };
}
