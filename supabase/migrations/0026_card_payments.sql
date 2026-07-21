-- =====================================================================
-- Ahorbit — Pago de tarjeta + transferencias externas (esquema y vistas).
-- Depende de 0025 (enum tx_kind ya tiene 'card_payment').
--
-- Cambios de fondo en el modelo:
--   * to_credit_line_id: a qué línea de crédito se abona un pago de tarjeta.
--   * is_external: una transferencia cuya cuenta destino NO es del usuario;
--     sale dinero de verdad, así que cuenta como egreso (no como movimiento
--     interno). Guarda to_account_id nulo.
--   * El pago de tarjeta (kind='card_payment') sale de account_id y baja la
--     deuda de to_credit_line_id.
--   * El gasto con débito ya trae account_id (lo copia el frontend), así que
--     descuenta de su cuenta ligada por la rama de 'expense' de siempre.
-- Re-ejecutable.
-- =====================================================================

alter table public.transactions
  add column if not exists to_credit_line_id uuid
    references public.credit_lines(id) on delete set null;

alter table public.transactions
  add column if not exists is_external boolean not null default false;

create index if not exists transactions_to_credit_line_idx
  on public.transactions(to_credit_line_id);

-- ---------------------------------------------------------------------
-- account_balances: el pago de tarjeta sale de la cuenta origen.
-- Misma lógica multimoneda que 0009. Una transferencia externa ya queda
-- bien: la rama de 'transfer' resta el origen y, al no haber to_account_id,
-- nada se vuelve a sumar.
-- ---------------------------------------------------------------------
drop view if exists public.account_balances;
create view public.account_balances
  with (security_invoker = true) as
select
  a.id            as account_id,
  a.user_id,
  a.name,
  a.currency,
  a.initial_balance
    + coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.account_id = a.id and t.kind = 'income'   and t.pending = false), 0)
    - coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.account_id = a.id and t.kind = 'expense'  and t.pending = false), 0)
    - coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.account_id = a.id and t.kind = 'transfer' and t.pending = false), 0)
    + coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.to_account_id = a.id and t.kind = 'transfer' and t.pending = false), 0)
    - coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.account_id = a.id and t.kind = 'card_payment' and t.pending = false), 0)
  as current_balance
from public.accounts a;

grant select on public.account_balances to authenticated;

-- ---------------------------------------------------------------------
-- credit_line_usage: la deuda ahora baja también con los pagos de tarjeta.
--   used = consumos(expense) − reembolsos(income) − pagos(card_payment)
-- ---------------------------------------------------------------------
drop view if exists public.credit_line_usage;
create view public.credit_line_usage
  with (security_invoker = true) as
with line_net as (
  select
    l.id as credit_line_id,
    coalesce((select sum(case when t.kind = 'expense' then 1 else -1 end
                         * case when t.currency = l.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        join public.cards c on c.id = t.card_id
        where c.credit_line_id = l.id
          and t.kind in ('expense', 'income') and t.pending = false), 0)
    - coalesce((select sum(case when t.currency = l.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.to_credit_line_id = l.id
          and t.kind = 'card_payment' and t.pending = false), 0) as used
  from public.credit_lines l
)
select
  l.id      as credit_line_id,
  l.user_id,
  l.name,
  l.currency,
  l.credit_limit,
  n.used,
  l.credit_limit - n.used as available
from public.credit_lines l
join line_net n on n.credit_line_id = l.id;

grant select on public.credit_line_usage to authenticated;

-- ---------------------------------------------------------------------
-- card_usage: `used` sigue siendo el gasto neto de ESA tarjeta. El
-- `available` es el de la LÍNEA: descuenta el consumo neto de todas sus
-- tarjetas y le suma los pagos de tarjeta de la línea.
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
  -- Gasto neto de esta tarjeta.
  coalesce((select sum(case when t.kind = 'expense' then 1 else -1 end
                       * case when t.currency = c.currency then t.amount
                              else coalesce(t.base_amount, t.amount) end)
      from public.transactions t
      where t.card_id = c.id
        and t.kind in ('expense', 'income') and t.pending = false), 0) as used,
  -- Disponible de la LÍNEA: consumo neto de todas sus tarjetas, menos pagos.
  coalesce(l.credit_limit, c.credit_limit, 0)
    - coalesce((select sum(case when t.kind = 'expense' then 1 else -1 end
                           * case when t.currency = c.currency then t.amount
                                  else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        join public.cards sib on sib.id = t.card_id
        where t.kind in ('expense', 'income') and t.pending = false
          and (case when c.credit_line_id is null
                    then sib.id = c.id
                    else sib.credit_line_id = c.credit_line_id end)), 0)
    + coalesce((select sum(case when t.currency = c.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.kind = 'card_payment' and t.pending = false
          and (case when c.credit_line_id is null
                    then false
                    else t.to_credit_line_id = c.credit_line_id end)), 0) as available
from public.cards c
left join public.credit_lines l on l.id = c.credit_line_id
where c.type = 'credit';

grant select on public.card_usage to authenticated;
