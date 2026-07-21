-- =====================================================================
-- Ahorbit — categorías del sistema: iconos y edición por admin.
--
-- 1) Los iconos de las categorías de sistema se habían sembrado con nombres
--    de iconos Lucide ('wallet', 'car', ...) que se renderizaban como texto
--    literal en la UI. Se sustituyen por emojis.
-- 2) Nueva política RLS: un admin puede editar las categorías del sistema
--    (para poder ajustar emoji/color/nombre desde la app).
-- Re-ejecutable.
-- =====================================================================

update public.categories c
set icon = m.emoji
from (values
  ('wallet',          '💼'),
  ('trending-up',     '📈'),
  ('plus-circle',     '➕'),
  ('utensils',        '🍽️'),
  ('shopping-bag',    '🛍️'),
  ('film',            '🎬'),
  ('home',            '🏠'),
  ('more-horizontal', '❓'),
  ('heart',           '🏥'),
  ('zap',             '🔌'),
  ('car',             '🚗')
) as m(lucide, emoji)
where c.is_system and c.icon = m.lucide;

-- Los admins pueden editar las categorías del sistema.
drop policy if exists categories_update_system_admin on public.categories;
create policy categories_update_system_admin on public.categories
  for update
  using (
    user_id is null
    and is_system
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.is_admin
    )
  )
  with check (
    user_id is null
    and is_system
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.is_admin
    )
  );
