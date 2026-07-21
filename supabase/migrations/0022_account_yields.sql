-- =====================================================================
-- Ahorbit — Rendimientos: tasa anual, tipo y retención de ISR.
-- Bancos y SOFIPOs mexicanas publican la tasa ANUAL (GAT nominal), no la
-- mensual, así que hasta ahora el usuario tenía que dividir a mano. Se
-- guarda el periodo en que se capturó para poder mostrarla como la
-- publica su banco y convertirla al vuelo.
-- También se distingue el rendimiento a la vista (se paga cada mes) del
-- de plazo fijo (se paga al vencimiento), y se permite descontar la
-- retención de ISR, que en México se calcula sobre el CAPITAL y es lo
-- que explica la diferencia contra el estado de cuenta.
-- El default 'monthly' preserva el significado de las tasas ya
-- capturadas: nada se reinterpreta.
-- Re-ejecutable.
-- =====================================================================
alter table public.accounts
  add column if not exists yield_rate_period text not null default 'monthly',
  add column if not exists yield_kind text not null default 'demand',
  add column if not exists yield_term_days int,
  add column if not exists yield_term_end date,
  add column if not exists withhold_isr boolean not null default false,
  add column if not exists isr_rate numeric(6,3);

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'accounts_yield_rate_period_check'
  ) then
    alter table public.accounts
      add constraint accounts_yield_rate_period_check
      check (yield_rate_period in ('monthly', 'annual'));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'accounts_yield_kind_check'
  ) then
    alter table public.accounts
      add constraint accounts_yield_kind_check
      check (yield_kind in ('demand', 'term'));
  end if;
end $$;
