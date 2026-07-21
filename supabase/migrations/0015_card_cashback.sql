-- =====================================================================
-- Ahorbit — MVP: cashback en tarjetas de crédito.
-- Marca si una tarjeta ofrece cashback (sin porcentaje, ya que varía por
-- tipo de transacción). El cashback recibido se registra como una
-- transacción de ingreso con la categoría de sistema "Cashback".
-- Re-ejecutable.
-- =====================================================================
alter table public.cards
  add column if not exists has_cashback boolean not null default false;

-- Categoría de sistema para registrar el cashback recibido.
-- (kind es el enum category_kind, por eso el cast explícito.)
insert into public.categories (name, kind, icon, color, is_system)
select v.name, v.kind::category_kind, v.icon, v.color, v.is_system
from (values
  ('Cashback', 'income', '💸', '#10b981', true)
) as v(name, kind, icon, color, is_system)
where not exists (
  select 1 from public.categories c where c.is_system = true and c.name = v.name
);
