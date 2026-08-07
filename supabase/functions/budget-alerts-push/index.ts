// Envía por push (FCM) los avisos de presupuesto pendientes. Hermana de
// budget-alerts-email: mismo cron, misma dedupe por budget_alerts, pero canal
// y elegibilidad distintos — ver pending_budget_push_alerts() en
// 0040_push_tokens.sql para el porqué de las diferencias.
//
// A diferencia del correo (opt-in explícito), el push no tiene checkbox: está
// implícito en tener la app instalada y sesión iniciada, que es cuando se
// registra el token (src/lib/pushNotifications.ts).
//
// Desplegar SIN verificación de JWT (lo llama el cron):
//   supabase functions deploy budget-alerts-push --no-verify-jwt
// Secrets: CRON_SECRET, FCM_SERVICE_ACCOUNT (JSON de la cuenta de servicio,
//   en base64 — ver _shared/fcm.ts)
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { parseServiceAccount, getFcmAccessToken, sendFcmPush } from '../_shared/fcm.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const CRON_SECRET = Deno.env.get('CRON_SECRET')!
const FCM_SERVICE_ACCOUNT = Deno.env.get('FCM_SERVICE_ACCOUNT')

interface PendingPushAlert {
  alert_id: string
  user_id: string
  push_token: string
  category_name: string | null
  level: 'warn' | 'over'
  percent: number
  spent: number
  amount: number
  currency: string
  period: string
  period_start: string
}

function money(value: number, currency: string): string {
  try {
    return new Intl.NumberFormat('es-MX', { style: 'currency', currency }).format(value)
  } catch {
    return `${value.toFixed(2)} ${currency}`
  }
}

function notificationFor(a: PendingPushAlert): { title: string; body: string } {
  const name = a.category_name ?? 'General (todas las categorías)'
  const title =
    a.level === 'over'
      ? `🚨 Excediste tu presupuesto de ${name}`
      : `🎯 Vas en ${Math.round(a.percent)}% de tu presupuesto de ${name}`
  const body = `${money(a.spent, a.currency)} de ${money(a.amount, a.currency)}`
  return { title, body }
}

serve(async (req) => {
  try {
    if (req.headers.get('x-cron-secret') !== CRON_SECRET) {
      return json({ error: 'forbidden' }, 403)
    }
    if (!FCM_SERVICE_ACCOUNT) return json({ error: 'FCM_SERVICE_ACCOUNT no configurado' }, 500)

    const body = await req.json().catch(() => ({}))
    const today =
      typeof body?.today === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(body.today)
        ? body.today
        : new Date().toISOString().slice(0, 10)
    const dryRun = body?.dryRun === true

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)

    const { data, error } = await admin.rpc('pending_budget_push_alerts', {
      p_today: today,
    })
    if (error) throw error

    const pending = (data ?? []) as PendingPushAlert[]
    if (pending.length === 0) return json({ today, alerts: 0, tokens: 0, sent: 0 })

    if (dryRun) {
      return json({
        today,
        dryRun: true,
        alerts: new Set(pending.map((p) => p.alert_id)).size,
        tokens: pending.length,
        preview: pending.map((p) => ({
          alertId: p.alert_id,
          token: `${p.push_token.slice(0, 12)}…`,
          ...notificationFor(p),
        })),
      })
    }

    const account = parseServiceAccount(FCM_SERVICE_ACCOUNT)
    const accessToken = await getFcmAccessToken(account)

    // Un usuario puede tener varios tokens (varios dispositivos). Se manda a
    // todos; el aviso se marca enviado si al menos uno recibió el push.
    const byAlert = new Map<string, PendingPushAlert[]>()
    for (const p of pending) {
      const list = byAlert.get(p.alert_id)
      if (list) list.push(p)
      else byAlert.set(p.alert_id, [p])
    }

    let sent = 0
    let failed = 0
    const deadTokens = new Set<string>()

    for (const [alertId, list] of byAlert) {
      const { title, body: notifBody } = notificationFor(list[0])
      let anyOk = false
      for (const p of list) {
        const result = await sendFcmPush(
          accessToken,
          account.project_id,
          p.push_token,
          { title, body: notifBody },
          { type: 'budget_alert', url: '/presupuestos' },
        )
        if (result.ok) anyOk = true
        else if (result.invalidToken) deadTokens.add(p.push_token)
        else console.error('budget-alerts-push falló para', p.user_id, result.error)
      }

      if (anyOk) {
        const { error: markError } = await admin
          .from('budget_alerts')
          .update({ notified_push: true })
          .eq('id', alertId)
        if (markError) console.error('no se pudo marcar notified_push:', markError.message)
        sent++
      } else {
        failed++
      }
    }

    // Limpieza de tokens muertos: evita reintentar contra un dispositivo que
    // ya desinstaló la app o rotó su token.
    if (deadTokens.size > 0) {
      await admin.from('push_tokens').delete().in('token', [...deadTokens])
    }

    return json({
      today,
      alerts: byAlert.size,
      tokens: pending.length,
      sent,
      failed,
      tokensRemoved: deadTokens.size,
    })
  } catch (error) {
    console.error('budget-alerts-push error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}
