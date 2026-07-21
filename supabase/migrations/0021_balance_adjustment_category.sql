-- =====================================================================
-- Ahorbit — Categoría de sistema "Ajuste de saldo".
-- Se usa al registrar un MSI que arrancó en un periodo anterior: si el
-- usuario confirma que ya pagó N mensualidades, se genera un ingreso de
-- ajuste con esa fecha para que el balance histórico no quede negativo
-- por un gasto que en realidad ya se venía pagando.
-- Mismo patrón de siembra que "Cashback" en 0015.
-- Re-ejecutable.
-- =====================================================================
insert into public.categories (name, kind, icon, color, is_system)
select v.name, v.kind::category_kind, v.icon, v.color, v.is_system
from (values
  ('Ajuste de saldo', 'income', '⚖️', '#64748b', true)
) as v(name, kind, icon, color, is_system)
where not exists (
  select 1 from public.categories c where c.is_system = true and c.name = v.name
);
