-- Dashboard's event trigger is not an end-user RPC.
-- Keep its DDL behavior, remove unnecessary API execution privileges.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;
