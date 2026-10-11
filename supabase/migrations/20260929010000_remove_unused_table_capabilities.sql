-- RLS does not constrain TRUNCATE. Ordinary API roles need no table-wide
-- TRUNCATE, REFERENCES, or TRIGGER capability, including inherited PUBLIC grants.
do $$
declare v_table record;
begin
 for v_table in
  select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind in ('r','p')
    and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass
      and d.objid=c.oid and d.deptype='e')
 loop
  execute format('revoke truncate, references, trigger on table public.%I from public, anon, authenticated',v_table.relname);
 end loop;
end;
$$;
;
