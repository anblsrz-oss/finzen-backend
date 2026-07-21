-- =====================================================================
-- Ahorbit — Seguimiento mes a mes de los planes MSI/diferidos.
-- Hasta ahora un plan (installment_plans) solo guardaba el total y la
-- mensualidad; no había registro de cuáles mensualidades ya se pagaron.
-- Este ledger anota cada mensualidad conciliada (normalmente al registrar
-- el pago de la tarjeta), para poder mostrar avance y faltante reales.
-- Re-ejecutable.
-- =====================================================================
create table if not exists public.installment_plan_payments (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  plan_id      uuid not null references public.installment_plans(id) on delete cascade,
  period_month date not null,                       -- primer día del mes, como yield_records
  amount       numeric(14,2) not null,
  paid         boolean not null default true,
  paid_at      timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  unique (plan_id, period_month)
);

create index if not exists installment_plan_payments_user_id_idx
  on public.installment_plan_payments(user_id);
create index if not exists installment_plan_payments_plan_id_idx
  on public.installment_plan_payments(plan_id);

alter table public.installment_plan_payments enable row level security;

drop policy if exists installment_plan_payments_select on public.installment_plan_payments;
create policy installment_plan_payments_select on public.installment_plan_payments for select
  using (user_id = auth.uid());

drop policy if exists installment_plan_payments_insert on public.installment_plan_payments;
create policy installment_plan_payments_insert on public.installment_plan_payments for insert
  with check (user_id = auth.uid());

drop policy if exists installment_plan_payments_update on public.installment_plan_payments;
create policy installment_plan_payments_update on public.installment_plan_payments for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists installment_plan_payments_delete on public.installment_plan_payments;
create policy installment_plan_payments_delete on public.installment_plan_payments for delete
  using (user_id = auth.uid());

grant select, insert, update, delete on public.installment_plan_payments to authenticated;
