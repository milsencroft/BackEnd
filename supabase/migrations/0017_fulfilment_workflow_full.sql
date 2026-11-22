-- NOTE: applied as-is, then immediately superseded by 0018. This migration left admin_set_fulfilment as an empty
-- stub (authoring mistake); 0018 creates the real function. Kept verbatim so the files match the database history.
drop function admin_set_fulfilment(uuid, fulfilment_status, text, text, text);
create function admin_set_fulfilment(p_order uuid, p_status fulfilment_status, p_courier text default null, p_tracking text default null,
  p_note text default null, p_tracking_url text default null, p_estimated_delivery date default null) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype; ok boolean; v_email text; f text := o_prev(); 
begin return; end $$;
drop function if exists o_prev();
