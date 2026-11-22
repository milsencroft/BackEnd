// Supabase Edge Function entry point. Secrets come from Edge Function secrets (never from the repo).
import { createApp } from "./lib/app.ts";
import { createRazorpayClient } from "./lib/razorpay.ts";
import { createStore } from "./lib/store.ts";

const env = (k: string) => Deno.env.get(k) ?? null;
const keyId = env("RAZORPAY_KEY_ID");
const keySecret = env("RAZORPAY_KEY_SECRET");

const app = createApp({
  store: createStore(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, env("SUPABASE_ANON_KEY")!),
  razorpay: keyId && keySecret ? createRazorpayClient(keyId, keySecret) : null,
  keyId,
  webhookSecret: env("RAZORPAY_WEBHOOK_SECRET"),
  allowedOrigin: env("ALLOWED_ORIGIN") ?? "*",
  log: (msg, extra) => console.log(JSON.stringify({ msg, ...extra })),
});

Deno.serve(app.fetch);
