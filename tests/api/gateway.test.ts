import { describe, expect, it } from "vitest";
import { setup } from "./helpers.ts";

const auth = { authorization: "Bearer good" };
const guest = { "x-cart-token": "g".repeat(40) };

describe("POST /rpc/:fn (database gateway)", () => {
  it("refuses functions that are not on the allowlist", async () => {
    const t = setup();
    for (const fn of ["_require", "begin_retail_checkout", "process_payment_captured", "pg_sleep", "cart_add", "admin_nothing"]) {
      expect((await t.post(`/rpc/${fn}`, {}, auth)).status).toBe(404);
    }
    expect(t.store.as).toHaveLength(0);
  });

  it("lets anyone call public functions, without a token", async () => {
    const t = setup(); t.store.results.shop_catalogue = [{ code: "A" }];
    const res = await t.post("/rpc/shop_catalogue", {});
    expect(await res.json()).toEqual({ data: [{ code: "A" }] });
    expect(t.store.as[0].token).toBeNull();
  });

  it("needs sign-in for customer and staff functions, and runs them with the caller's own token", async () => {
    const t = setup();
    expect((await t.post("/rpc/my_orders", {})).status).toBe(401);
    expect((await t.post("/rpc/admin_summary", {}, { authorization: "Bearer bad" })).status).toBe(401);
    await t.post("/rpc/admin_summary", { p_x: 1 }, auth);
    expect(t.store.as[0]).toEqual({ token: "good", fn: "admin_summary", args: { p_x: 1 } });
  });

  it("answers permission and role quietly for visitors who are not signed in", async () => {
    const t = setup();
    expect(await (await t.post("/rpc/my_permissions", {})).json()).toEqual([]);
    expect(await (await t.post("/rpc/my_role", {})).json()).toBeNull();
  });

  it("passes short database error codes through and hides everything else", async () => {
    const t = setup();
    t.store.failures.admin_grant_staff = "customer_not_found";
    const res = await t.post("/rpc/admin_grant_staff", {}, auth);
    expect(res.status).toBe(400); expect(await res.json()).toEqual({ error: "customer_not_found" });
    t.store.failures.admin_grant_staff = 'permission denied for table "orders" at line 4';
    const r2 = await t.post("/rpc/admin_grant_staff", {}, auth);
    expect(r2.status).toBe(500); expect(await r2.json()).toEqual({ error: "internal_error" });
  });

  it("removes the storage files when media is deleted", async () => {
    const t = setup(); t.store.results.admin_delete_media = ["products/a.jpg"];
    await t.post("/rpc/admin_delete_media", { p_id: "x", p_reason: "r" }, auth);
    expect(t.store.removed).toEqual([["products/a.jpg"]]);
  });
});

describe("POST /admin/media/upload-url", () => {
  it("needs media.manage and picks the path itself", async () => {
    const t = setup();
    expect((await t.post("/admin/media/upload-url", { content_type: "image/png" })).status).toBe(401);
    t.store.perms = ["orders.view"];
    expect((await t.post("/admin/media/upload-url", { content_type: "image/png" }, auth)).status).toBe(403);
    t.store.perms = ["media.manage"];
    expect((await t.post("/admin/media/upload-url", { content_type: "text/html" }, auth)).status).toBe(400);
    const res = await t.post("/admin/media/upload-url", { content_type: "video/mp4", path: "../../etc" }, auth);
    expect((await res.json()).path).toMatch(/^videos\/[0-9a-f-]{36}\.mp4$/);
    const p = await t.post("/admin/media/upload-url", { content_type: "image/webp", poster: true }, auth);
    expect((await p.json()).path).toMatch(/^posters\//);
  });
});

describe("cart routes", () => {
  it("needs either a sign-in or a visitor token", async () => {
    const t = setup();
    expect((await t.call("/cart")).status).toBe(401);
    expect((await t.call("/cart", { headers: { "x-cart-token": "short" } })).status).toBe(401);
    expect((await t.call("/cart", { headers: { authorization: "Bearer bad" } })).status).toBe(401);
  });

  it("adds through the database, which decides; refusals become clear errors", async () => {
    const t = setup(); t.store.results.cart_view = { lines: [], count: 0, subtotal_paise: 0 };
    t.store.results.cart_add = "ok";
    const res = await t.post("/cart/items", { sku: "MC-KER-001-50ML", qty: 2 }, guest);
    expect(res.status).toBe(200);
    expect(t.store.called("cart_add")[0].args).toEqual({ p_customer: null, p_guest: "g".repeat(40), p_sku: "MC-KER-001-50ML", p_bundle: null, p_qty: 2 });
    t.store.results.cart_add = "launch_only";
    const r2 = await t.post("/cart/items", { sku: "MC-KER-001-50ML", qty: 1 }, auth);
    expect(r2.status).toBe(409); expect(await r2.json()).toEqual({ error: "launch_only" });
    expect(t.store.called("cart_add")[1].args.p_customer).toBe("cust-1");
  });

  it("rejects malformed lines before the database", async () => {
    const t = setup();
    for (const b of [{ qty: 1 }, { sku: "MC-KER-001-50ML", bundle: "MC-DUO-001", qty: 1 }, { sku: "MC-KER-001-50ML", qty: 0 }, { sku: "MC-KER-001-50ML", qty: 6 }, { sku: "bad sku!", qty: 1 }]) {
      expect((await t.post("/cart/items", b, guest)).status).toBe(400);
    }
    expect(t.store.calls).toHaveLength(0);
  });

  it("merges the visitor cart into the account cart after sign-in", async () => {
    const t = setup();
    expect((await t.post("/cart/merge", {}, guest)).status).toBe(401);
    await t.post("/cart/merge", {}, { ...auth, ...guest });
    expect(t.store.called("cart_merge")[0].args).toEqual({ p_customer: "cust-1", p_guest: "g".repeat(40) });
  });
});
