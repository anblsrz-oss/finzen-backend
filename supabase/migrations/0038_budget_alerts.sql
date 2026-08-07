-- =====================================================================
-- Ahorbit — Avisos de presupuesto.
--
-- Esta tabla existe SOLO para deduplicar. La clave natural
-- (presupuesto, periodo, nivel) garantiza un aviso por umbral cruzado por
-- periodo, pase lo que pase con el gasto después: si baja del 80% y vuelve
-- a subir NO se re-avisa (evita el flapping al editar o borrar una
-- transacción). Pasar de 'warn' a 'over' sí es información nueva y genera
-- una segunda fila.
--
-- Al cambiar de periodo cambia period_start y el ciclo se reinicia solo,
-- sin job de limpieza.
-- Re-ejecutable.
-- =====================================================================

create table if not exists public.budget_alerts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  budget_id    uuid not null references public.budgets(id) on delete cascade,
  period_start date not null,
  level        text not null check (level in ('warn','over')),
  -- Congelados al momento del aviso: es lo que se le dijo al usuario,
  -- aunque el gasto cambie después.
  percent      numeric(6,2) not null,
  spent        numeric(14,2) not null,
  amount       numeric(14,2) not null,
  -- Un canal puede entregarse aunque otro ya lo haya hecho, sin duplicar
  -- el aviso ni la fila. email y push son para las fases siguientes.
  notified_in_app boolean not null default false,
  notified_email  boolean not null default false,
  notified_push   boolean not null default false,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);

-- La única barrera anti-spam, y es suficiente: da igual cuántas veces se
-- llame la función, desde cuántos dispositivos o en cuántas pestañas.
create unique index if not exists budget_alerts_dedupe_uidx
  on public.budget_alerts(budget_id, period_start, level);

-- Para el badge de avisos sin leer.
create index if not exists budget_alerts_user_unread_idx
  on public.budget_alerts(user_id, created_at desc) where read_at is null;

alter table public.budget_alerts enable row level security;

drop policy if exists budget_alerts_all_own on public.budget_alerts;
create policy budget_alerts_all_own on public.budget_alerts for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update, delete on public.budget_alerts to authenticated;

-- ---------------------------------------------------------------------
-- Evalúa los presupuestos del usuario en sesión y registra los avisos que
-- falten. Idempotente por el índice único: llamarla 50 veces seguidas
-- inserta como máximo una fila por (presupuesto, periodo, nivel).
-- Devuelve SOLO las filas nuevas, que es lo que el cliente debe mostrar.
--
-- En cada llamada se inserta únicamente el nivel ACTUAL, no ambos: un
-- presupuesto que arranca al 120% genera una sola fila 'over'; uno que va
-- de 85% a 120% genera 'warn' y luego 'over'. Cero doble aviso.
--
-- SECURITY DEFINER porque los valores los calcula el servidor (los mismos
-- que usarán el correo y el push). Por eso el filtro user_id = auth.uid()
-- es OBLIGATORIO: dentro de un definer, budget_status_at corre como el
-- owner y NO le aplica RLS.
-- ---------------------------------------------------------------------
create or replace function public.record_budget_alerts(p_today date)
returns setof public.budget_alerts
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'record_budget_alerts requiere una sesión';
  end if;

  return query
  insert into public.budget_alerts
    (user_id, budget_id, period_start, level, percent, spent, amount, notified_in_app)
  select
    s.user_id, s.budget_id, s.period_start, s.status,
    coalesce(s.percent, 0), s.spent, s.amount, true
  from public.budget_status_at(p_today) s
  where s.user_id = uid          -- imprescindible: el definer bypassa RLS
    and s.status in ('warn','over')
  on conflict (budget_id, period_start, level) do nothing
  returning *;
end;
$$;

grant execute on function public.record_budget_alerts(date) to authenticated;
