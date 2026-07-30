-- =====================================================================
-- Ahorbit — Tokens de dispositivo para captura automática de SMS
-- Cada teléfono con "captura automática" guarda un token; el receptor
-- nativo (app cerrada, sin sesión JWT) lo envía a la Edge Function
-- `ingest-sms`, que lo resuelve a un user_id. Se guarda solo el HASH
-- (sha256) del token, nunca el token en claro.
-- Pegar completo en Supabase -> SQL Editor -> Run. Re-ejecutable.
-- =====================================================================

create table if not exists public.sms_device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  token_hash   text not null unique,          -- sha256 hex del token del dispositivo
  device_label text,                          -- ej. "Pixel 8" (informativo)
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);

create index if not exists sms_device_tokens_user_id_idx
  on public.sms_device_tokens(user_id);

-- =====================================================================
-- ROW LEVEL SECURITY
-- El usuario gestiona (crea/lista/revoca) sus propios dispositivos desde
-- la app con su sesión. La Edge Function `ingest-sms` lee/actualiza con
-- service_role (salta RLS), así que no necesita política de lectura ancha.
-- =====================================================================
alter table public.sms_device_tokens enable row level security;

drop policy if exists sms_device_tokens_all_own on public.sms_device_tokens;
create policy sms_device_tokens_all_own on public.sms_device_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
