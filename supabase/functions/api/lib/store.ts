import { createClient } from "@supabase/supabase-js";
import { DbError, type PaymentRow, type Store } from "./types.ts";

export function createStore(url: string, serviceKey: string, anonKey: string): Store {
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  return {
    async authUser(token) {
      const { data, error } = await admin.auth.getUser(token);
      return error || !data.user ? null : { id: data.user.id };
    },
    async customerIdForUser(userId) {
      const { data } = await admin.from("customers").select("id").eq("auth_user_id", userId).eq("is_active", true).maybeSingle();
      return data?.id ?? null;
    },
    async permissions(token) {
      const asUser = createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false } });
      const { data, error } = await asUser.rpc("my_permissions");
      if (error) throw new DbError(error.message);
      return (data as string[]) ?? [];
    },
    async rpc<T>(fn: string, args: Record<string, unknown>) {
      const { data, error } = await admin.rpc(fn, args);
      if (error) throw new DbError(error.message);
      return data as T;
    },
    async paymentForOrder(orderId) {
      const { data } = await admin.from("payments").select("id, razorpay_payment_id, amount_paise, status").eq("order_id", orderId)
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      return (data as PaymentRow | null) ?? null;
    },
    async refundsForPayment(paymentId) {
      const { data } = await admin.from("refunds").select("status, amount_paise").eq("payment_id", paymentId);
      return data ?? [];
    },
    async audit(e) {
      await admin.from("audit_log").insert({
        actor_customer_id: e.actor, action: e.action, entity_type: e.entityType, entity_id: e.entityId, reason: e.reason, after_data: e.after ?? null,
      });
    },
  };
}
