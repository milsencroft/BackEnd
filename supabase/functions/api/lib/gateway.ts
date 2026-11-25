// Which database functions the browser may reach through the API. Everything else is refused.
// The functions themselves enforce permissions (_require) and row ownership; this list only limits the surface.
export const PUBLIC_FUNCTIONS = new Set([
  "public_launch_state", "public_media_slots", "public_page", "public_pages", "public_society_tiers",
  "launch_catalogue", "shop_catalogue", "shop_bundles", "newsletter_subscribe",
]);

export const USER_FUNCTIONS = new Set([
  "my_permissions", "my_role", "my_society", "my_orders", "my_profile", "my_addresses", "my_wishlist", "my_order_status",
  "my_save_address", "my_delete_address", "my_toggle_wishlist", "my_reserve_launch_slot", "update_my_profile",
]);

export const ADMIN_FUNCTIONS = new Set([
  "admin_add_order_note", "admin_admit_reentry", "admin_catalogue", "admin_coupon_redemptions", "admin_create_coupons",
  "admin_delete_media", "admin_grant_staff", "admin_list_coupons", "admin_list_couriers", "admin_list_media", "admin_list_pages",
  "admin_list_staff", "admin_log_order_update", "admin_newsletter_list", "admin_newsletter_unsubscribe", "admin_order_detail",
  "admin_order_packing", "admin_order_updates", "admin_outbox_overview", "admin_pack_check", "admin_process_launch_cycle",
  "admin_register_embed", "admin_register_media", "admin_register_video", "admin_report", "admin_revoke_staff",
  "admin_run_society_queues", "admin_save_courier", "admin_save_page", "admin_search_orders", "admin_set_coupon_active",
  "admin_set_coupon_rules", "admin_set_fulfilment", "admin_set_launch_capacity", "admin_set_launch_status", "admin_set_media_slot",
  "admin_set_page_status", "admin_set_product_images", "admin_set_tier_benefits", "admin_society_dispatch", "admin_society_overview",
  "admin_summary", "admin_update_media_alt", "admin_update_setting",
  "admin_inventory_list", "admin_set_stock", "admin_adjust_stock",
  "admin_launch_list", "admin_get_setting", "admin_product_names", "admin_tier_numbers",
  "admin_offer_choices", "admin_list_offers", "admin_save_offer", "admin_set_offer_active",
]);

export type FnKind = "public" | "user" | "admin" | null;
export const kindOf = (fn: string): FnKind =>
  PUBLIC_FUNCTIONS.has(fn) ? "public" : USER_FUNCTIONS.has(fn) ? "user" : ADMIN_FUNCTIONS.has(fn) ? "admin" : null;

/** SQL error text that is safe to show: a short identifier-like code, never a Postgres internal message. */
export const safeErrorCode = (m: string) => (/^[a-z][a-z0-9_]{1,60}$/.test(m) ? m : null);
