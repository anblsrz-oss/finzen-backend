-- =====================================================================
-- Ahorbit — MVP 4: tarjetas visuales (tipo físicas).
-- Guarda solo los últimos 4 dígitos y un color/gradiente. NUNCA el número
-- completo, CVC ni fecha de vencimiento (por seguridad).
-- Re-ejecutable.
-- =====================================================================
alter table public.cards
  add column if not exists last4 text check (last4 is null or last4 ~ '^\d{4}$'),
  add column if not exists color text;
