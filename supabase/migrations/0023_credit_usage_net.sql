-- =====================================================================
-- Ahorbit — El uso de la línea de crédito se vuelve neto.
-- Hasta ahora `used` solo sumaba gastos, así que nunca bajaba: ni al
-- pagar la tarjeta, ni con un reembolso, ni con el ingreso de ajuste que
-- se genera al capturar un MSI cuyas primeras mensualidades ya se
-- pagaron en periodos anteriores (ver 0021). Ese ajuste quedaba invisible
-- para el disponible y la línea se veía más consumida de lo que estaba.
-- Ahora se resta todo ingreso cargado a una tarjeta de la línea.
-- Las transferencias son cuenta→cuenta y nunca llevan card_id, así que
-- no hay riesgo de contarlas dos veces.
-- Re-ejecutable.
-- =====================================================================

drop view if exists public.credit_line_usage;
create view public.credit_line_usage
  with (security_invoker = true) as
select
  l.id      as credit_line_id,
  l.user_id,
  l.name,
  l.currency,
  l.credit_limit,
  coalesce((select sum(case when t.kind = 'expense' then 1 else -1 end
                       * case when t.currency = l.currency then t.amount
                              else coalesce(t.base_amount, t.amount) end)
      from public.transactions t
      join public.cards c on c.id = t.card_id
      where c.credit_line_id = l.id
        and t.kind in ('expense', 'income') and t.pending = false), 0) as used,
  l.credit_limit
    - coalesce((select sum(case when t.kind = 'expense' then 1 else -1 end
                           * case when t.currency = l.currency then t.amount
                                  else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        join public.cards c on c.id = t.card_id
        where c.credit_line_id = l.id
          and t.kind in ('expense', 'income') and t.pending = false), 0) as available
from public.credit_lines l;

grant select on public.credit_line_usage to authenticated;

-- ---------------------------------------------------------------------
-- card_usage: mismo criterio neto. `used` sigue siendo el gasto de ESA
-- tarjeta y el disponible el de toda su línea (hermanas incluidas).
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
  -- Disponible de la LÍNEA: descuenta el gasto neto de todas sus tarjetas.
  coalesce(l.credit_limit, c.credit_limit, 0)
    - coalesce((select sum(case when t.kind = 'expense' then 1 else -1 end
                           * case when t.currency = c.currency then t.amount
                                  else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        join public.cards sib on sib.id = t.card_id
        where t.kind in ('expense', 'income') and t.pending = false
          and (case when c.credit_line_id is null
                    then sib.id = c.id
                    else sib.credit_line_id = c.credit_line_id end)), 0) as available
from public.cards c
left join public.credit_lines l on l.id = c.credit_line_id
where c.type = 'credit';

grant select on public.card_usage to authenticated;
