-- Flags Premium configurables desde Admin para el selector de periodo
-- (Hoy/Esta semana/Este mes/Personalizado) en Resumen y Movimientos.

alter table public.app_config
  add column if not exists dashboard_period_filter_is_premium boolean not null default false,
  add column if not exists transactions_period_filter_is_premium boolean not null default false;
