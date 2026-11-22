// Contracts between the HTTP layer and the outside world. Tests replace these with fakes.
export class DbError extends Error {}

export interface PaymentRow {
  id: string;
  razorpay_payment_id: string | null;
  amount_paise: number;
  status: string;
}

export interface RazorpayClient {
  createOrder(input: { amountPaise: number; receipt: string; notes?: Record<string, string> }): Promise<{ id: string }>;
  refundPayment(paymentId: string, input: { amountPaise: number; notes?: Record<string, string> }): Promise<{ id: string }>;
}

export interface Store {
  authUser(token: string): Promise<{ id: string } | null>;
  customerIdForUser(userId: string): Promise<string | null>;
  /** Permissions of the signed-in user, computed by the database (my_permissions) with the user's own JWT. */
  permissions(token: string): Promise<string[]>;
  /** Calls a service-role-only SQL function. Throws DbError(message) with the SQL exception text. */
  rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T>;
  paymentForOrder(orderId: string): Promise<PaymentRow | null>;
  refundsForPayment(paymentId: string): Promise<{ status: string; amount_paise: number }[]>;
  audit(entry: { actor: string | null; action: string; entityType: string; entityId: string; reason: string | null; after?: unknown }): Promise<void>;
}

export interface Deps {
  store: Store;
  razorpay: RazorpayClient | null;
  keyId: string | null;
  webhookSecret: string | null;
  allowedOrigin?: string;
  log?: (msg: string, extra?: Record<string, unknown>) => void;
}
