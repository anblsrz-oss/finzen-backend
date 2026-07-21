-- =====================================================================
-- Ahorbit — Fechas reales de corte y pago por periodo.
-- Los días de corte y pago de una línea son nominales (día 15, día 5),
-- pero varios bancos los recorren uno o dos días cuando caen en día
-- inhábil. Cuando la línea tiene `dates_may_shift`, al llegar la fecha
-- calculada se le pregunta al usuario si fue la real, y aquí queda el
-- histórico de lo que confirmó.
-- Re-ejecutable.
-- =====================================================================
create table if not exists public.credit_line_periods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  credit_line_id uuid not null references public.credit_lines(id) on delete cascade,
  period_month date not null,          -- primer día del mes, como yield_records
  cut_date date not null,
  payment_date date not null,
  confirmed boolean not null default false,
  created_at timestamptz not null default now(),
  unique (credit_line_id, period_month)
);

create index if not exists credit_line_periods_user_id_idx
  on public.credit_line_periods(user_id);

alter table public.credit_line_periods enable row level security;

drop policy if exists credit_line_periods_select on public.credit_line_periods;
create policy credit_line_periods_select on public.credit_line_periods for select
  using (user_id = auth.uid());

drop policy if exists credit_line_periods_insert on public.credit_line_periods;
create policy credit_line_periods_insert on public.credit_line_periods for insert
  with check (user_id = auth.uid());

drop policy if exists credit_line_periods_update on public.credit_line_periods;
create policy credit_line_periods_update on public.credit_line_periods for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists credit_line_periods_delete on public.credit_line_periods;
create policy credit_line_periods_delete on public.credit_line_periods for delete
  using (user_id = auth.uid());

grant select, insert, update, delete on public.credit_line_periods to authenticated;
