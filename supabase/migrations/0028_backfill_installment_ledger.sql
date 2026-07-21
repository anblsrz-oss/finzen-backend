-- =====================================================================
-- Ahorbit — Recálculo histórico del crédito (parte de datos).
--
-- El modelo viejo usaba un ingreso de "Ajuste de saldo" (con card_id) para
-- representar las mensualidades MSI que ya se habían pagado ANTES de empezar
-- a registrar en la app. Ese ingreso sigue siendo válido: baja la deuda de la
-- línea (credit_line_usage lo netea por card_id) y en los reportes nuevos se
-- clasifica solo como reembolso, no como efectivo — el "parche" por categoría
-- ya no se usa en el código. NO se borra: eliminarlo resucitaría deuda que en
-- realidad ya estaba pagada.
--
-- Lo que falta es representar esas mensualidades en el ledger nuevo
-- (installment_plan_payments) para que el avance mes a mes sea correcto.
-- Este backfill es ADITIVO e idempotente (on conflict do nothing): por cada
-- ingreso de ajuste, marca como pagadas las primeras N mensualidades del plan
-- correspondiente (N = monto / mensualidad).
--
-- El plan se identifica por: misma tarjeta, creado en/antes del ajuste (mismo
-- lote de captura) y con la mensualidad que divide el monto del ajuste.
-- =====================================================================
do $$
declare
  adj record;
  pl record;
  paid_count int;
  i int;
  pm date;
begin
  for adj in
    select t.id as tx_id, t.card_id, t.amount, t.created_at, t.user_id
    from public.transactions t
    join public.categories c on c.id = t.category_id
    where c.is_system and c.name = 'Ajuste de saldo'
      and t.card_id is not null
  loop
    -- Plan más reciente de la misma tarjeta creado junto con el ajuste, cuya
    -- mensualidad divide el monto (residual < 1 peso por redondeo).
    select p.* into pl
    from public.installment_plans p
    where p.card_id = adj.card_id
      and p.monthly_payment > 0
      and p.created_at <= adj.created_at + interval '2 seconds'
      and abs(adj.amount - round(adj.amount / p.monthly_payment) * p.monthly_payment) < 1
    order by p.created_at desc
    limit 1;

    if pl.id is null then
      continue;
    end if;

    paid_count := round(adj.amount / pl.monthly_payment);
    if paid_count < 1 then paid_count := 1; end if;
    if paid_count > pl.months then paid_count := pl.months; end if;

    for i in 0..(paid_count - 1) loop
      pm := date_trunc('month', (pl.start_date + (i || ' months')::interval))::date;
      insert into public.installment_plan_payments
        (user_id, plan_id, period_month, amount, paid)
      values (pl.user_id, pl.id, pm, pl.monthly_payment, true)
      on conflict (plan_id, period_month) do nothing;
    end loop;
  end loop;
end $$;
