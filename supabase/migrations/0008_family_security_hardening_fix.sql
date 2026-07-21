-- Ahorbit — Corrección del hardening anterior (0007).
-- Este proyecto tiene un event trigger que otorga EXECUTE directamente a los
-- roles anon/authenticated/service_role en cada función nueva (no vía PUBLIC),
-- así que `revoke ... from public` no removía esos grants directos. Hay que
-- revocar explícitamente del rol correspondiente.
-- Re-ejecutable.

revoke execute on function public.jwt_email() from anon;
revoke execute on function public.validate_family_tx() from anon;
revoke execute on function public.validate_family_tx() from authenticated;
