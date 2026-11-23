-- Expected result: error PASS_ROLLBACK (everything is rolled back).
do $$
begin
  perform set_config('request.jwt.claims', '{"sub":"e657ce70-0442-451a-b394-68dc59cb6dcb","role":"authenticated"}', true);
  set local role authenticated;
  perform admin_save_page('shipping', 'legal', 'Shipping', 's', 'body text', 'test');
  set local role anon;
  if public_page('shipping') is not null then raise exception 'FAIL draft visible'; end if;
  if jsonb_array_length(public_pages('legal')) <> 0 then raise exception 'FAIL draft listed'; end if;
  set local role authenticated;
  perform admin_set_page_status('shipping', 'published', 'test');
  set local role anon;
  if public_page('shipping')->>'title' <> 'Shipping' then raise exception 'FAIL not visible'; end if;
  begin perform admin_list_pages(); raise exception 'FAIL anon list'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  set local role authenticated;
  perform admin_set_page_status('shipping', 'archived', 'test');
  set local role anon;
  if public_page('shipping') is not null then raise exception 'FAIL archived visible'; end if;
  set local role authenticated;
  begin perform admin_save_page('Bad Slug', 'page', 't', null, '', 'x'); raise exception 'FAIL slug'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform admin_save_page('okslug', 'page', 't', null, '', ''); raise exception 'FAIL reason'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  raise exception 'PASS_ROLLBACK';
end $$;
