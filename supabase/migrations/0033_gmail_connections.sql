-- =====================================================================
-- Ahorbit — Conexiones de Gmail para captura de correo EN TIEMPO REAL
-- (Gmail push / Pub/Sub). Guarda por usuario el refresh_token de Google
-- (para que el servidor consulte Gmail sin el usuario presente), el
-- history_id (punto de partida de users.history.list) y la expiración del
-- watch (hay que renovarlo antes de 7 días).
--
-- SEGURIDAD: el refresh_token es la credencial más sensible del sistema.
-- El cliente NUNCA debe poder leerlo: se le conceden permisos de columna a
-- todas MENOS refresh_token. Solo las Edge Functions (service_role, que
-- salta RLS) leen/escriben el token.
-- Pegar completo en Supabase -> SQL Editor -> Run. Re-ejecutable.
-- =====================================================================

create table if not exists public.gmail_connections (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  email            text,
  refresh_token    text,                 -- sensible; solo service_role
  history_id       text,                 -- último historyId procesado
  watch_expiration timestamptz,          -- vencimiento del users.watch (<7 días)
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.gmail_connections enable row level security;

-- El usuario solo opera sobre su propia fila.
drop policy if exists gmail_connections_own on public.gmail_connections;
create policy gmail_connections_own on public.gmail_connections
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Permisos de columna: el cliente puede LEER el estado (email, history_id,
-- expiración) y BORRAR su fila (desconectar), pero NO puede leer ni escribir
-- refresh_token. Las Edge Functions usan service_role y no dependen de esto.
revoke all on public.gmail_connections from authenticated;
grant select (user_id, email, history_id, watch_expiration, created_at, updated_at)
  on public.gmail_connections to authenticated;
grant delete on public.gmail_connections to authenticated;
