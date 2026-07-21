-- =====================================================================
-- Ahorbit — colores de tema configurables por admin.
-- theme_colors (jsonb): { brand, light:{bg,surface}, dark:{bg,surface} }.
-- null = usar el tema por defecto. RLS de update ya restringido a admin (0014).
-- Re-ejecutable.
-- =====================================================================
alter table public.app_config
  add column if not exists theme_colors jsonb;
