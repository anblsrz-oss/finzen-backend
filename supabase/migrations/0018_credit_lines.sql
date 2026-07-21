-- =====================================================================
-- Ahorbit — Líneas de crédito compartidas.
-- Varias tarjetas del mismo banco suelen compartir UNA sola línea de
-- crédito: el límite es el mismo para todas (dos tarjetas Nu con $20,000
-- no dan $40,000) y también comparten día de corte y día de pago.
-- El límite, las fechas y el disponible pasan a vivir en la línea; la
-- tarjeta solo aporta su gasto individual.
-- Re-ejecutable.
-- =====================================================================

create table if not exists public.credit_lines (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  name text not null,                       -- "Nu", "BBVA Azul"
  bank_name text,
  credit_limit numeric(14,2) not null,
  currency text not null default 'MXN',
  cut_day int check (cut_day between 1 and 31),
  payment_day int check (payment_day between 1 and 31),
  -- Algunos bancos recorren corte/pago cuando cae en día inhábil.
  dates_may_shift boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists credit_lines_user_id_idx on public.credit_lines(user_id);

alter table public.cards
  add column if not exists credit_line_id uuid
    references public.credit_lines(id) on delete set null;

create index if not exists cards_credit_line_id_idx on public.cards(credit_line_id);

-- ---------------------------------------------------------------------
-- RLS: cada quien ve y edita solo sus líneas.
-- ---------------------------------------------------------------------
alter table public.credit_lines enable row level security;

drop policy if exists credit_lines_select on public.credit_lines;
create policy credit_lines_select on public.credit_lines for select
  using (user_id = auth.uid());

drop policy if exists credit_lines_insert on public.credit_lines;
create policy credit_lines_insert on public.credit_lines for insert
  with check (user_id = auth.uid());

drop policy if exists credit_lines_update on public.credit_lines;
create policy credit_lines_update on public.credit_lines for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists credit_lines_delete on public.credit_lines;
create policy credit_lines_delete on public.credit_lines for delete
  using (user_id = auth.uid());

grant select, insert, update, delete on public.credit_lines to authenticated;

-- ---------------------------------------------------------------------
-- Backfill: toda tarjeta de crédito existente estrena su propia línea con
-- los datos que hoy tiene sueltos. Así el frontend lee límite y fechas de
-- un solo lugar, sin ramas para "tarjetas viejas". Idempotente: solo toca
-- las que aún no tienen línea.
-- ---------------------------------------------------------------------
do $$
declare
  c record;
  new_line_id uuid;
begin
  for c in
    select id, user_id, name, currency, credit_limit, cut_day, payment_day
    from public.cards
    where type = 'credit' and credit_line_id is null
  loop
    insert into public.credit_lines
      (user_id, name, credit_limit, currency, cut_day, payment_day)
    values
      (c.user_id, c.name, coalesce(c.credit_limit, 0), c.currency, c.cut_day, c.payment_day)
    returning id into new_line_id;

    update public.cards set credit_line_id = new_line_id where id = c.id;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Uso agregado por línea: suma el gasto de TODAS sus tarjetas contra el
-- límite único. Misma lógica multimoneda que card_usage (base_amount
-- cuando la moneda de la transacción difiere de la de la línea).
-- card_usage se conserva: el gasto por tarjeta individual sigue siendo
-- dato útil, pero el límite y el disponible se leen de aquí.
-- ---------------------------------------------------------------------
drop view if exists public.credit_line_usage;
create view public.credit_line_usage
  with (security_invoker = true) as
select
  l.id      as credit_line_id,
  l.user_id,
  l.name,
  l.currency,
  l.credit_limit,
  coalesce((select sum(case when t.currency = l.currency then t.amount
                            else coalesce(t.base_amount, t.amount) end)
      from public.transactions t
      join public.cards c on c.id = t.card_id
      where c.credit_line_id = l.id and t.kind = 'expense' and t.pending = false), 0) as used,
  l.credit_limit
    - coalesce((select sum(case when t.currency = l.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        join public.cards c on c.id = t.card_id
        where c.credit_line_id = l.id and t.kind = 'expense' and t.pending = false), 0) as available
from public.credit_lines l;

grant select on public.credit_line_usage to authenticated;

-- ---------------------------------------------------------------------
-- card_usage se redefine: `used` sigue siendo el gasto de ESA tarjeta, pero
-- el límite y el disponible pasan a ser los de su línea (dos tarjetas Nu no
-- dan dos disponibles). Se conserva el fallback a las columnas legadas de
-- `cards` para una tarjeta de crédito que se quedara sin línea.
-- La consume la vista de Familia ("Disponible total"), que así no se
-- desactualiza al editar el límite de la línea.
-- ---------------------------------------------------------------------
drop view if exists public.card_usage;
create view public.card_usage
  with (security_invoker = true) as
select
  c.id           as card_id,
  c.user_id,
  c.name,
  c.currency,
  coalesce(l.credit_limit, c.credit_limit) as credit_limit,
  -- Gasto de esta tarjeta.
  coalesce((select sum(case when t.currency = c.currency then t.amount
                            else coalesce(t.base_amount, t.amount) end)
      from public.transactions t
      where t.card_id = c.id and t.kind = 'expense' and t.pending = false), 0) as used,
  -- Disponible de la LÍNEA: descuenta el gasto de todas sus tarjetas.
  coalesce(l.credit_limit, c.credit_limit, 0)
    - coalesce((select sum(case when t.currency = c.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        join public.cards sib on sib.id = t.card_id
        where t.kind = 'expense' and t.pending = false
          and (case when c.credit_line_id is null
                    then sib.id = c.id
                    else sib.credit_line_id = c.credit_line_id end)), 0) as available
from public.cards c
left join public.credit_lines l on l.id = c.credit_line_id
where c.type = 'credit';

grant select on public.card_usage to authenticated;
