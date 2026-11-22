alter type fulfilment_status add value if not exists 'in_transit';
alter type fulfilment_status add value if not exists 'out_for_delivery';
alter type fulfilment_status add value if not exists 'delivery_failed';
alter type fulfilment_status add value if not exists 'return_requested';
alter table orders add column if not exists tracking_url text;
alter table orders add column if not exists shipped_at timestamptz;
alter table orders add column if not exists estimated_delivery date;
