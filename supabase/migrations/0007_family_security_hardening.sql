-- Ahorbit — Hardening de seguridad para el plan familiar, según supabase advisors.
-- 1) jwt_email() no tenía search_path fijo (function_search_path_mutable).
-- 2) Los helpers quedaban ejecutables por 'anon' vía RPC porque el REVOKE
--    original solo quitaba el privilegio a 'anon', pero PUBLIC (que incluye a
--    anon Y authenticated por herencia) seguía teniendo EXECUTE por defecto de
--    Postgres al crear la función. Hay que revocar de PUBLIC y re-otorgar solo
--    a authenticated donde corresponde.
-- Re-ejecutable.

create or replace function public.jwt_email() returns text
language sql stable security definer set search_path = public as
$$ select lower(coalesce(auth.jwt()->>'email','')) $$;

revoke execute on function public.jwt_email() from public;
grant execute on function public.jwt_email() to authenticated;

revoke execute on function public.is_family_owner(uuid) from public;
grant execute on function public.is_family_owner(uuid) to authenticated;

revoke execute on function public.is_family_member(uuid) from public;
grant execute on function public.is_family_member(uuid) to authenticated;

revoke execute on function public.has_family_invite(uuid) from public;
grant execute on function public.has_family_invite(uuid) to authenticated;

-- Solo se invoca vía trigger; nadie debe poder llamarla directo por RPC.
revoke execute on function public.validate_family_tx() from public;
