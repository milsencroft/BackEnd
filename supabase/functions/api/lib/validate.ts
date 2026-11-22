export interface Address {
  name: string; phone: string; line1: string; line2?: string; city: string; state_code: string; pincode: string;
}
export interface RetailItem { sku?: string; bundle?: string; qty: number }

const str = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

/** Keeps only known keys (no arbitrary JSON ends up in the orders table) and mirrors the SQL rules. */
export function parseAddress(x: unknown): Address | null {
  if (!x || typeof x !== "object") return null;
  const a = x as Record<string, unknown>;
  const out: Address = {
    name: str(a.name, 80), phone: str(a.phone, 10), line1: str(a.line1, 120), city: str(a.city, 60),
    state_code: str(a.state_code, 2), pincode: str(a.pincode, 6),
  };
  const line2 = str(a.line2, 120);
  if (line2) out.line2 = line2;
  if (!out.name || !out.line1 || !out.city) return null;
  if (!/^[6-9][0-9]{9}$/.test(out.phone)) return null;
  if (!/^[1-9][0-9]{5}$/.test(out.pincode)) return null;
  if (!/^[0-9]{2}$/.test(out.state_code)) return null;
  return out;
}

export function parseRetailItems(x: unknown): RetailItem[] | null {
  if (!Array.isArray(x) || x.length < 1 || x.length > 10) return null;
  const items: RetailItem[] = [];
  for (const it of x) {
    if (!it || typeof it !== "object") return null;
    const r = it as Record<string, unknown>;
    const qty = r.qty;
    if (typeof qty !== "number" || !Number.isInteger(qty) || qty < 1 || qty > 5) return null;
    const sku = typeof r.sku === "string" ? r.sku : undefined;
    const bundle = typeof r.bundle === "string" ? r.bundle : undefined;
    if ((sku === undefined) === (bundle === undefined)) return null;
    const code = (sku ?? bundle)!;
    if (!/^[A-Za-z0-9-]{3,40}$/.test(code)) return null;
    items.push(sku !== undefined ? { sku, qty } : { bundle, qty });
  }
  return items;
}

export const isCode = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9-]{1,40}$/.test(v);

/** SQL exception text -> HTTP status. Anything not listed is an internal error. */
export const KNOWN_ERRORS: Record<string, number> = {
  invalid_address: 400, invalid_items: 400, invalid_item: 400, invalid_coupon: 400,
  launch_only: 409, out_of_stock: 409,
};
