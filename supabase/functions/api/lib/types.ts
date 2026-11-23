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
  /** Calls a SQL function as the caller: anon when token is null, otherwise with the user's JWT so RLS and _require() apply. */
  callAs<T = unknown>(token: string | null, fn: string, args: Record<string, unknown>): Promise<T>;
  /** Signed upload URL / delete for the product-media bucket. Callers must already be authorised. */
  signedUpload(path: string): Promise<{ signed_url: string; token: string; path: string }>;
  removeMedia(paths: string[]): Promise<void>;
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
