// Envía por correo los avisos de presupuesto pendientes. Lo llama un cron
// (pg_cron + pg_net) una vez al día; se protege con un secret, igual que
// gmail-watch-renew.
//
// Un correo POR USUARIO con todos sus avisos, no uno por presupuesto: quien
// tiene seis presupuestos y se pasa de tres no quiere tres correos.
//
// Solo llegan correos a quien activó profiles.budget_alerts_email (por
// defecto está apagado). El filtro vive en record_budget_alerts_all.
//
// Desplegar SIN verificación de JWT (lo llama el cron):
//   supabase functions deploy budget-alerts-email --no-verify-jwt
// Secrets: CRON_SECRET, RESEND_API_KEY
// Opcionales: RESEND_FROM_EMAIL, APP_URL
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const CRON_SECRET = Deno.env.get('CRON_SECRET')!
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') ?? 'Ahorbit <onboarding@resend.dev>'
const APP_URL = Deno.env.get('APP_URL') ?? 'https://finze.xyz'

interface PendingAlert {
  alert_id: string
  user_id: string
  email: string
  category_name: string | null
  level: 'warn' | 'over'
  percent: number
  spent: number
  amount: number
  currency: string
  period: string
  period_start: string
}

const PERIOD_LABELS: Record<string, string> = {
  daily: 'diario',
  weekly: 'semanal',
  biweekly: 'quincenal',
  monthly: 'mensual',
}

function money(value: number, currency: string): string {
  try {
    return new Intl.NumberFormat('es-MX', { style: 'currency', currency }).format(value)
  } catch {
    // Moneda no reconocida por Intl: mejor un número crudo que un 500.
    return `${value.toFixed(2)} ${currency}`
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function renderRow(a: PendingAlert): string {
  const name = escapeHtml(a.category_name ?? 'General (todas las categorías)')
  const period = PERIOD_LABELS[a.period] ?? a.period
  const color = a.level === 'over' ? '#dc2626' : '#d97706'
  const headline =
    a.level === 'over'
      ? `Excediste tu presupuesto ${period}`
      : `Vas en ${Math.round(a.percent)}% de tu presupuesto ${period}`
  return `
    <tr>
      <td style="padding:12px 0;border-bottom:1px solid #e2e8f0;">
        <div style="font-weight:600;color:#0f172a;">${a.level === 'over' ? '🚨' : '🎯'} ${name}</div>
        <div style="color:${color};font-size:14px;margin-top:2px;">${headline}</div>
        <div style="color:#64748b;font-size:13px;margin-top:2px;">
          ${money(a.spent, a.currency)} de ${money(a.amount, a.currency)}
        </div>
      </td>
    </tr>`
}

function renderEmail(alerts: PendingAlert[]): string {
  return `
    <div style="font-family:sans-serif;max-width:520px;margin:0 auto;">
      <h2 style="color:#0f172a;">Cómo van tus presupuestos</h2>
      <p style="color:#475569;font-size:14px;">
        ${alerts.length === 1
          ? 'Un presupuesto cruzó el límite que configuraste.'
          : `${alerts.length} presupuestos cruzaron el límite que configuraste.`}
      </p>
      <table style="width:100%;border-collapse:collapse;">${alerts.map(renderRow).join('')}</table>
      <p style="margin-top:24px;">
        <a href="${APP_URL}/presupuestos"
           style="background:#0d9488;color:#fff;padding:10px 18px;border-radius:8px;
                  text-decoration:none;font-size:14px;">Ver mis presupuestos</a>
      </p>
      <p style="color:#94a3b8;font-size:12px;margin-top:24px;">
        Puedes desactivar estos correos en Configuración → Presupuestos.
      </p>
    </div>`
}

serve(async (req) => {
  try {
    // Autorización del cron: header x-cron-secret.
    if (req.headers.get('x-cron-secret') !== CRON_SECRET) {
      return json({ error: 'forbidden' }, 403)
    }
    if (!RESEND_API_KEY) return json({ error: 'RESEND_API_KEY no configurado' }, 500)

    // El cron corre a las 14:00 UTC (08:00 en México) justamente para que la
    // fecha UTC ya coincida con la local. `today` se puede forzar por body
    // para poder probar la función a mano sin esperar al cron.
    const body = await req.json().catch(() => ({}))
    const today =
      typeof body?.today === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(body.today)
        ? body.today
        : new Date().toISOString().slice(0, 10)
    const dryRun = body?.dryRun === true

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)

    const { data, error } = await admin.rpc('record_budget_alerts_all', {
      p_today: today,
    })
    if (error) throw error

    const pending = (data ?? []) as PendingAlert[]
    if (pending.length === 0) return json({ today, users: 0, alerts: 0, sent: 0 })

    // Un correo por usuario, con todos sus avisos juntos.
    const byUser = new Map<string, PendingAlert[]>()
    for (const a of pending) {
      const list = byUser.get(a.user_id)
      if (list) list.push(a)
      else byUser.set(a.user_id, [a])
    }

    if (dryRun) {
      return json({
        today,
        dryRun: true,
        users: byUser.size,
        alerts: pending.length,
        preview: [...byUser.values()].map((list) => ({
          to: list[0].email,
          subject: subjectFor(list),
          alerts: list.length,
        })),
      })
    }

    let sent = 0
    let failed = 0
    for (const [userId, list] of byUser) {
      try {
        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            from: FROM_EMAIL,
            to: [list[0].email],
            subject: subjectFor(list),
            html: renderEmail(list),
          }),
        })
        if (!res.ok) throw new Error(await res.text())

        // Marcar solo lo que sí salió: si Resend falla, el aviso queda
        // pendiente y el cron lo reintenta mañana en vez de perderse.
        const { error: markError } = await admin
          .from('budget_alerts')
          .update({ notified_email: true })
          .in('id', list.map((a) => a.alert_id))
        if (markError) throw markError

        sent++
      } catch (e) {
        console.error('budget-alerts-email falló para', userId, (e as Error).message)
        failed++
      }
    }

    return json({ today, users: byUser.size, alerts: pending.length, sent, failed })
  } catch (error) {
    console.error('budget-alerts-email error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})

function subjectFor(list: PendingAlert[]): string {
  const over = list.filter((a) => a.level === 'over').length
  if (over > 0) {
    return over === 1 && list.length === 1
      ? `🚨 Excediste tu presupuesto de ${list[0].category_name ?? 'gastos'}`
      : `🚨 Excediste ${over} de tus presupuestos`
  }
  return list.length === 1
    ? `🎯 Vas en ${Math.round(list[0].percent)}% de tu presupuesto de ${list[0].category_name ?? 'gastos'}`
    : `🎯 ${list.length} presupuestos cerca del límite`
}

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}
