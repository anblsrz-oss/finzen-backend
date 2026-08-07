-- =====================================================================
-- Ahorbit — Fase B de presupuestos: aviso por correo.
--
-- Añade la preferencia por usuario y la versión "para todos los usuarios"
-- de record_budget_alerts, que es la que llama el cron a través de la Edge
-- Function budget-alerts-email.
-- Re-ejecutable.
-- =====================================================================

-- Opt-in explícito: nadie recibe correo hasta que lo activa en
-- Configuración. El aviso in-app sigue siendo el canal por defecto.
alter table public.profiles
  add column if not exists budget_alerts_email boolean not null default false;

-- ---------------------------------------------------------------------
-- Versión para el cron: recorre TODOS los usuarios, no solo al de la
-- sesión (de hecho corre sin sesión: auth.uid() es null).
--
-- Hace dos cosas distintas a propósito:
--   1) Registra los avisos que falten de todos los usuarios. Así el
--      historial queda completo aunque el usuario no abra la app en
--      días, y el banner in-app se lo encuentra la próxima vez.
--   2) Devuelve lo que está pendiente de ENVIAR POR CORREO, que no es lo
--      mismo que "lo que se acaba de insertar": un aviso registrado ayer
--      desde la app, de alguien que activó el correo, también toca
--      enviarlo. Por eso el paso 2 consulta la tabla en vez de usar el
--      RETURNING del insert.
--
-- budget_status_at es invoker-rights, pero al llamarla desde aquí corre
-- como el owner de esta función y por tanto ve todas las filas. Eso es
-- justo lo que el cron necesita, y es también la razón por la que esta
-- función NO puede quedar expuesta (ver el revoke de abajo).
-- ---------------------------------------------------------------------
create or replace function public.record_budget_alerts_all(p_today date)
returns table (
  alert_id      uuid,
  user_id       uuid,
  email         text,
  category_name text,   -- null = presupuesto general
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
-- Las columnas de RETURNS TABLE son variables dentro del cuerpo, y varias se
-- llaman igual que columnas reales (period_start, level, amount…). Sin esto,
-- el ON CONFLICT de abajo falla con "column reference is ambiguous". No se
-- pueden renombrar: sus nombres son las claves del JSON que consume la Edge
-- Function.
#variable_conflict use_column
begin
  -- 1) Registrar lo que falte. notified_in_app queda en false: este aviso
  --    no se le ha enseñado todavía a nadie dentro de la app.
  insert into public.budget_alerts
    (user_id, budget_id, period_start, level, percent, spent, amount)
  select
    s.user_id, s.budget_id, s.period_start, s.status,
    coalesce(s.percent, 0), s.spent, s.amount
  from public.budget_status_at(p_today) s
  where s.status in ('warn','over')
  on conflict (budget_id, period_start, level) do nothing;

  -- 2) Lo pendiente de enviar por correo, solo de quien lo activó.
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
    -- Un aviso de hace dos meses ya no le sirve a nadie. Evita que una
    -- caída larga del cron dispare una avalancha de correos al volver.
    and a.period_start >= p_today - interval '31 days'
  order by a.user_id, a.created_at;
end;
$$;

-- IMPRESCINDIBLE. En este proyecto los privilegios por defecto del
-- esquema public otorgan EXECUTE a anon y authenticated en TODA función
-- nueva (pg_default_acl, defaclobjtype='f'). Sin este revoke, cualquiera
-- con la llave publishable podría llamar a esta función y leer los
-- correos y los montos de todos los usuarios.
revoke execute on function public.record_budget_alerts_all(date)
  from anon, authenticated, public;

-- ---------------------------------------------------------------------
-- CRON (no va en esta migración porque lleva el CRON_SECRET en claro;
-- se corre a mano en el SQL Editor, igual que gmail-watch-renew-daily).
--
-- 14:00 UTC = 08:00 en México. La hora importa: budget_status_at usa la
-- fecha que le pasa la función, que a esa hora ya coincide en UTC y en
-- hora local, así que ningún periodo se evalúa un día antes de tiempo.
--
--   select cron.schedule('budget-alerts-daily', '0 14 * * *', $$
--     select net.http_post(
--       url     := 'https://vujlizgyharlhcmfgkti.supabase.co/functions/v1/budget-alerts-email',
--       headers := jsonb_build_object(
--                    'Content-Type','application/json',
--                    'x-cron-secret','<CRON_SECRET>')
--     );
--   $$);
--
-- Para quitarlo:  select cron.unschedule('budget-alerts-daily');
-- Para probarlo a mano sin enviar nada, el body admite
-- {"dryRun": true} y {"today": "YYYY-MM-DD"}.
-- ---------------------------------------------------------------------
