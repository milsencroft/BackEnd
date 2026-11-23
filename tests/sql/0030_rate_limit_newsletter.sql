-- Expected result: error PASS_ROLLBACK.
do $$
declare i int; ok boolean;
begin
  for i in 1..3 loop
    if not rate_limit_hit('t:a', 3, 3600) then raise exception 'FAIL blocked early'; end if;
  end loop;
  if rate_limit_hit('t:a', 3, 3600) then raise exception 'FAIL not blocked'; end if;
  if not rate_limit_hit('t:b', 3, 3600) then raise exception 'FAIL keys not independent'; end if;
  set local role anon;
  begin perform rate_limit_hit('t:c', 3, 60); raise exception 'FAIL anon limiter'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform newsletter_subscribe('not-an-email'); raise exception 'FAIL email'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform newsletter_subscribe('Same@Example.com'); perform newsletter_subscribe('same@example.com');
  begin perform admin_newsletter_list(); raise exception 'FAIL anon list'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  reset role;
  if (select count(*) from newsletter_subscribers where lower(email) = 'same@example.com') <> 1 then raise exception 'FAIL duplicate'; end if;
  raise exception 'PASS_ROLLBACK';
end $$;
