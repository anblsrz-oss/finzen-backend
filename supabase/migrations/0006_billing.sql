-- Ahorbit — Facturación (Stripe) y teléfono.
-- Agrega a profiles el customer de Stripe, la vigencia de premium y el teléfono.
-- Sin cambios de RLS: profiles sigue siendo select-own; estas columnas solo se
-- escriben desde el service role (edge functions), nunca desde el cliente.
-- Re-ejecutable.

alter table public.profiles
  add column if not exists stripe_customer_id text,
  add column if not exists premium_until timestamptz,
  add column if not exists phone text;
