-- =====================================================================
-- Ahorbit — Presupuestos por categoría + un presupuesto general.
--
-- Modelo: una fila por presupuesto. `category_id` NULL = presupuesto
-- GENERAL (todo el gasto del usuario). Un presupuesto por categoría y uno
-- solo general: presupuestos solapados sobre la misma categoría harían
-- ambiguo el "% consumido" y duplicarían los avisos.
--
-- El periodo es un ATRIBUTO del presupuesto, no parte de su identidad:
-- cambiar de mensual a semanal EDITA la fila, no crea una segunda.
--
-- Qué consume presupuesto: TODO gasto (kind='expense') en su tx_date, sin
-- importar el medio de pago (crédito, débito, efectivo, cuenta). Los
-- card_payment y transfer NO consumen: el pago de tarjeta es la
-- liquidación de un consumo que ya se contó el día de la compra. Es el
-- criterio "económico / al consumir", el mismo de balanceEconomic en
-- useReports.ts.
--
-- El cálculo vive aquí y no en el cliente porque las fases siguientes
-- (correo por cron, push) corren sin React y deben dar exactamente el
-- mismo número que la app; dos implementaciones de la misma regla siempre
-- divergen.
-- Re-ejecutable.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) TABLA
-- ---------------------------------------------------------------------
create table if not exists public.budgets (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  -- NULL = presupuesto general (todas las categorías de gasto).
  category_id uuid references public.categories(id) on delete cascade,
  amount      numeric(14,2) not null check (amount > 0),
  -- Moneda del límite. Sin selector en el MVP: se llena con
  -- profiles.main_currency. La columna existe para no migrar después.
  currency    text not null default 'MXN',
  -- text + check en vez de enum: agregar 'quarterly' mañana es
  -- drop constraint + add constraint, y no un alter type irreversible.
  period      text not null default 'monthly'
                check (period in ('daily','weekly','biweekly','monthly')),
  -- Reservado para periodos anclados ("mi mes va del 25 al 24"). Hoy
  -- nadie lo lee: el cálculo usa calendario fijo. Existe para no migrar
  -- datos cuando se implemente.
  anchor_day  int check (anchor_day between 1 and 31),
  -- Umbral de aviso 1-100. NULL = hereda profiles.budget_alert_threshold.
  alert_threshold int check (alert_threshold between 1 and 100),
  is_active   boolean not null default true,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Un presupuesto por categoría, y UNO solo general.
-- unique(user_id, category_id) por sí solo NO impide varios generales: en
-- Postgres dos NULL son distintos entre sí. De ahí los dos parciales.
create unique index if not exists budgets_one_per_category_uidx
  on public.budgets(user_id, category_id) where category_id is not null;
create unique index if not exists budgets_one_general_uidx
  on public.budgets(user_id) where category_id is null;

create index if not exists budgets_user_id_idx on public.budgets(user_id);
create index if not exists budgets_category_id_idx on public.budgets(category_id);

alter table public.budgets enable row level security;

drop policy if exists budgets_all_own on public.budgets;
create policy budgets_all_own on public.budgets for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update, delete on public.budgets to authenticated;

-- ---------------------------------------------------------------------
-- 2) COLUMNAS ADITIVAS
-- ---------------------------------------------------------------------

-- Umbral de aviso por defecto del usuario, editable en /configuracion.
-- Lo usan los presupuestos que no definen el suyo propio.
-- No requiere tocar RLS: profiles_update_own ya existe y
-- protect_profile_privileged_cols() (0009) solo congela is_premium,
-- is_admin, id, email y created_at.
alter table public.profiles
  add column if not exists budget_alert_threshold int not null default 80;

do $$
begin
  alter table public.profiles
    add constraint profiles_budget_alert_threshold_check
    check (budget_alert_threshold between 1 and 100);
exception when duplicate_object then null;
end $$;

-- Flag Premium (apagado: en este MVP los presupuestos son gratis) y
-- máximo de presupuestos del plan gratis. 0 = ilimitado, mismo convenio
-- que free_max_accounts / free_max_cards / free_max_transactions (ver el
-- helper asLimit() en useAppConfig.ts). Arranca en 0 para que el MVP salga
-- sin restricción: monetizarlo después es cambiar el número desde /admin,
-- sin desplegar código.
alter table public.app_config
  add column if not exists budgets_is_premium boolean not null default false,
  add column if not exists free_max_budgets int not null default 0;

-- ---------------------------------------------------------------------
-- 3) ARITMÉTICA DEL PERIODO (calendario fijo)
--
-- mensual  = día 1 → fin de mes
-- quincenal= 1-15 y 16 → fin de mes
-- semanal  = lunes a domingo. date_trunc('week') en Postgres arranca en
--            LUNES, igual que weekStartISO() en src/lib/dates.ts, así que
--            frontend y backend coinciden sin conversión.
-- diario   = el propio día
--
-- anchor_day se ignora por ahora; cuando se implemente entra como tercer
-- argumento con default null y estas firmas siguen siendo válidas.
-- ---------------------------------------------------------------------
create or replace function public.budget_period_start(p_period text, p_date date)
returns date
language sql
immutable
as $$
  select case p_period
    when 'daily'    then p_date
    when 'weekly'   then date_trunc('week', p_date)::date
    when 'biweekly' then case
                           when extract(day from p_date) <= 15
                             then date_trunc('month', p_date)::date
                           else (date_trunc('month', p_date) + interval '15 days')::date
                         end
    when 'monthly'  then date_trunc('month', p_date)::date
  end
$$;

create or replace function public.budget_period_end(p_period text, p_date date)
returns date
language sql
immutable
as $$
  select case p_period
    when 'daily'    then p_date
    when 'weekly'   then (date_trunc('week', p_date) + interval '6 days')::date
    when 'biweekly' then case
                           when extract(day from p_date) <= 15
                             then (date_trunc('month', p_date) + interval '14 days')::date
                           else (date_trunc('month', p_date) + interval '1 month - 1 day')::date
                         end
    when 'monthly'  then (date_trunc('month', p_date) + interval '1 month - 1 day')::date
  end
$$;

-- ---------------------------------------------------------------------
-- 4) ESTADO DE LOS PRESUPUESTOS
--
-- Parametrizada por fecha, no por current_date: current_date en Supabase
-- es UTC, y a las 19:00 del último día del mes en México ya es el día
-- siguiente en UTC — el periodo saltaría antes de tiempo. El cliente pasa
-- su fecha LOCAL con todayISO().
--
-- Invoker rights (el default): las policies de budgets y transactions
-- aplican al llamador, así que un authenticated solo ve lo suyo. La
-- Edge Function con service_role ve todo y filtra por user_id.
-- ---------------------------------------------------------------------
create or replace function public.budget_status_at(p_today date)
returns table (
  budget_id       uuid,
  user_id         uuid,
  category_id     uuid,
  category_name   text,     -- null = general; la etiqueta la pone el cliente
  category_icon   text,
  category_color  text,
  period          text,
  period_start    date,
  period_end      date,
  amount          numeric,
  currency        text,
  spent           numeric,  -- confirmado (pending = false)
  spent_pending   numeric,  -- por confirmar; se muestra, no dispara avisos
  remaining       numeric,
  percent         numeric,  -- 0..∞, NO capado: la UI necesita mostrar "137%"
  alert_threshold int,      -- efectivo: el del presupuesto o el del perfil
  status          text      -- 'ok' | 'warn' | 'over'
)
language sql
stable
set search_path = public
as $$
  with base as (
    select
      b.id, b.user_id, b.category_id, b.amount, b.currency, b.period,
      c.name  as category_name,
      c.icon  as category_icon,
      c.color as category_color,
      coalesce(b.alert_threshold, p.budget_alert_threshold, 80) as thr,
      public.budget_period_start(b.period, p_today) as ps,
      public.budget_period_end(b.period, p_today)   as pe
    from public.budgets b
    join public.profiles p on p.id = b.user_id
    left join public.categories c on c.id = b.category_id
    where b.is_active
  ),
  agg as (
    select
      base.*,
      -- Confirmado. pending = false es consistente con account_balances /
      -- card_usage / credit_line_usage: un pendiente de SMS puede ser el
      -- duplicado del correo y no vale disparar un aviso por él.
      coalesce((
        select sum(case when t.currency = base.currency then t.amount
                        else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.user_id = base.user_id
          and t.kind = 'expense'      -- card_payment/transfer NO consumen
          and t.pending = false
          and t.family_id is null     -- MVP individual
          and t.tx_date between base.ps and base.pe
          and (base.category_id is null or t.category_id = base.category_id)
      ), 0) as spent,
      -- Por confirmar: informativo, para pintar "+$X por revisar".
      coalesce((
        select sum(case when t.currency = base.currency then t.amount
                        else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.user_id = base.user_id
          and t.kind = 'expense'
          and t.pending = true
          and t.family_id is null
          and t.tx_date between base.ps and base.pe
          and (base.category_id is null or t.category_id = base.category_id)
      ), 0) as spent_pending
    from base
  )
  select
    agg.id,
    agg.user_id,
    agg.category_id,
    agg.category_name,
    agg.category_icon,
    agg.category_color,
    agg.period,
    agg.ps,
    agg.pe,
    agg.amount,
    agg.currency,
    agg.spent,
    agg.spent_pending,
    agg.amount - agg.spent,
    round(agg.spent * 100.0 / nullif(agg.amount, 0), 2),
    agg.thr,
    case
      when agg.spent >= agg.amount then 'over'
      when agg.spent * 100.0 / nullif(agg.amount, 0) >= agg.thr then 'warn'
      else 'ok'
    end
  from agg;
$$;

grant execute on function public.budget_status_at(date) to authenticated;

-- Vista sobre current_date: la usa el cron (fases siguientes) y sirve para
-- validar a mano en el SQL Editor. Una sola copia de la lógica.
drop view if exists public.budget_status;
create view public.budget_status
  with (security_invoker = true)
  as select * from public.budget_status_at(current_date);

grant select on public.budget_status to authenticated;
