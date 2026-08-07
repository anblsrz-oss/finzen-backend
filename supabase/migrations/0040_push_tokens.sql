-- =====================================================================
-- Ahorbit — Fase C de presupuestos: aviso push (FCM).
--
-- Tabla push_tokens: un token de registro FCM por dispositivo, espejo
-- estructural de sms_device_tokens (0032). A diferencia del token de SMS,
-- el token FCM NO se hashea: no es una credencial (no sirve para enviar
-- nada sin las credenciales de service account del proyecto), es un
-- identificador de entrega, igual de sensible que una dirección de correo.
--
-- Además refactoriza record_budget_alerts_all (0039) para compartir el
-- paso de "registrar lo que falte" con la nueva ruta de push, en vez de
-- duplicar el insert ...  on conflict do nothing.
-- Re-ejecutable.
-- =====================================================================

create table if not exists public.push_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  token      text not null unique,   -- token de registro FCM
  platform   text not null default 'android' check (platform in ('android','ios','web')),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists push_tokens_user_id_idx on public.push_tokens(user_id);

alter table public.push_tokens enable row level security;

drop policy if exists push_tokens_all_own on public.push_tokens;
create policy push_tokens_all_own on public.push_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.push_tokens to authenticated;

-- ---------------------------------------------------------------------
-- Paso de registro compartido entre los canales (correo, push, y el que
-- venga después). Antes vivía duplicado dentro de record_budget_alerts_all;
-- se extrae aquí para que insertar el mismo aviso dos veces en el mismo
-- tick de cron (uno desde el paso de correo, otro desde el de push) siga
-- siendo un no-op, sin arriesgar que diverjan si alguno cambia.
-- ---------------------------------------------------------------------
create or replace function public._register_budget_alerts(p_today date)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.budget_alerts
    (user_id, budget_id, period_start, level, percent, spent, amount)
  select
    s.user_id, s.budget_id, s.period_start, s.status,
    coalesce(s.percent, 0), s.spent, s.amount
  from public.budget_status_at(p_today) s
  where s.status in ('warn','over')
  on conflict (budget_id, period_start, level) do nothing;
end;
$$;

revoke execute on function public._register_budget_alerts(date)
  from anon, authenticated, public;

-- Reemplaza la versión de 0039: mismo contrato de columnas (la Edge
-- Function budget-alerts-email ya desplegada las consume por nombre), solo
-- cambia que ahora delega el registro en la función compartida.
create or replace function public.record_budget_alerts_all(p_today date)
returns table (
  alert_id      uuid,
  user_id       uuid,
  email         text,
  category_name text,
  level         text,
  percent       numeric,
  spent         numeric,
  amount        numeric,
  currency      text,
  period        text,
  period_start  date
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public._register_budget_alerts(p_today);

  return query
  select
    a.id, a.user_id, p.email, c.name, a.level, a.percent,
    a.spent, a.amount, b.currency, b.period, a.period_start
  from public.budget_alerts a
  join public.profiles p on p.id = a.user_id
  join public.budgets  b on b.id = a.budget_id
  left join public.categories c on c.id = b.category_id
  where a.notified_email = false
    and p.budget_alerts_email
    and p.email is not null
    and a.period_start >= p_today - interval '31 days'
  order by a.user_id, a.created_at;
end;
$$;

revoke execute on function public.record_budget_alerts_all(date)
  from anon, authenticated, public;

-- ---------------------------------------------------------------------
-- Avisos pendientes de enviar por push, uno por (aviso, dispositivo): si
-- el usuario tiene el teléfono y una tablet registrados, se manda a los
-- dos. A diferencia del correo, aquí NO hay opt-in explícito: el push está
-- implícito en tener la app instalada y sesión iniciada (que es cuando se
-- registra el token). El límite temporal de 31 días evita una avalancha si
-- el cron estuvo caído mucho tiempo.
-- ---------------------------------------------------------------------
create or replace function public.pending_budget_push_alerts(p_today date)
returns table (
  alert_id      uuid,
  user_id       uuid,
  push_token    text,
  category_name text,
  level         text,
  percent       numeric,
  spent         numeric,
  amount        numeric,
  currency      text,
  period        text,
  period_start  date
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public._register_budget_alerts(p_today);

  return query
  select
    a.id, a.user_id, t.token, c.name, a.level, a.percent,
    a.spent, a.amount, b.currency, b.period, a.period_start
  from public.budget_alerts a
  join public.push_tokens t on t.user_id = a.user_id
  join public.budgets     b on b.id = a.budget_id
  left join public.categories c on c.id = b.category_id
  where a.notified_push = false
    and a.period_start >= p_today - interval '31 days'
  order by a.user_id, a.created_at;
end;
$$;

revoke execute on function public.pending_budget_push_alerts(date)
  from anon, authenticated, public;

-- ---------------------------------------------------------------------
-- CRON (no va aquí, lleva el CRON_SECRET en claro; se corre a mano en el
-- SQL Editor, igual que budget-alerts-daily en 0039).
--
-- Mismo horario que el correo (14:00 UTC = 08:00 CST): llegan juntos, un
-- solo momento del día en el que el usuario ve "cómo van mis presupuestos"
-- por los dos canales a la vez.
--
--   select cron.schedule('budget-alerts-push-daily', '0 14 * * *', $$
--     select net.http_post(
--       url     := 'https://vujlizgyharlhcmfgkti.supabase.co/functions/v1/budget-alerts-push',
--       headers := jsonb_build_object(
--                    'Content-Type','application/json',
--                    'x-cron-secret','<CRON_SECRET>')
--     );
--   $$);
--
-- Para quitarlo:  select cron.unschedule('budget-alerts-push-daily');
-- Para probar sin enviar nada: body {"dryRun": true} y {"today": "YYYY-MM-DD"}.
-- ---------------------------------------------------------------------
