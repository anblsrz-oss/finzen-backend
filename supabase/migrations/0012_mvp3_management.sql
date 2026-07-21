-- =====================================================================
-- Ahorbit — MVP 3 (gestión): eliminar familia + etiqueta de beca.
-- Re-ejecutable (IF NOT EXISTS / CREATE OR REPLACE).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Eliminar familia completa (solo el dueño).
--    Borra los gastos familiares (de todos los miembros, por eso es
--    security definer), luego la familia (cascade: miembros + tarjetas
--    compartidas). Pensado para descartar una familia por completo.
-- ---------------------------------------------------------------------
create or replace function public.delete_family(p_family_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from families f
    where f.id = p_family_id and f.owner_id = auth.uid()
  ) then
    raise exception 'Solo el dueño puede eliminar la familia';
  end if;

  delete from transactions where family_id = p_family_id;
  delete from families where id = p_family_id;  -- cascade a members/shared_cards
end $$;

-- Solo usuarios autenticados (dueños) la llaman por RPC; anon/public no.
revoke execute on function public.delete_family(uuid) from anon, public;
grant execute on function public.delete_family(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2) Etiqueta de beca en cuentas y tarjetas (marcador visual).
-- ---------------------------------------------------------------------
alter table public.accounts
  add column if not exists is_scholarship   boolean not null default false,
  add column if not exists scholarship_name text;

alter table public.cards
  add column if not exists is_scholarship   boolean not null default false,
  add column if not exists scholarship_name text;
