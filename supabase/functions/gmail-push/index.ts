import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  refreshAccessToken,
  listAddedMessageIds,
  getMessage,
  getAttachmentData,
} from '../_shared/gmail.ts'
import {
  stageFromGmailMessage,
  type CardRow,
  type EmailRule,
} from '../_shared/parseEmail.ts'

// Webhook de Gmail push (Pub/Sub). Google publica al llegar un correo; aquí se
// leen los mensajes nuevos y se insertan como transacciones pendientes,
// reutilizando el parseo compartido de sync-email.
//
// Desplegar SIN verificación de JWT (lo llama Pub/Sub, no un usuario):
//   supabase functions deploy gmail-push --no-verify-jwt
// La push subscription debe apuntar a:
//   https://<REF>.supabase.co/functions/v1/gmail-push?token=<GMAIL_PUSH_SECRET>
//
// Secrets: GMAIL_PUSH_SECRET, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const PUSH_SECRET = Deno.env.get('GMAIL_PUSH_SECRET')!

serve(async (req) => {
  try {
    // Validar que el POST viene de nuestra suscripción de Pub/Sub.
    const url = new URL(req.url)
    if (url.searchParams.get('token') !== PUSH_SECRET) {
      return new Response('forbidden', { status: 403 })
    }

    const body = await req.json().catch(() => ({}))
    const dataB64: string | undefined = body?.message?.data
    if (!dataB64) return ok() // ack: mensaje sin data

    const decoded = JSON.parse(atob(dataB64)) as {
      emailAddress?: string
      historyId?: string | number
    }
    const email = decoded.emailAddress
    const pushHistoryId = decoded.historyId ? String(decoded.historyId) : null
    if (!email) return ok()

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)

    const { data: conn } = await admin
      .from('gmail_connections')
      .select('user_id, refresh_token, history_id')
      .eq('email', email)
      .maybeSingle()
    if (!conn?.refresh_token) return ok() // desconocido o sin token: ack y salir

    const userId = conn.user_id as string
    const startHistoryId = (conn.history_id as string) ?? pushHistoryId
    if (!startHistoryId) {
      // Sin punto de partida: guardar el del push para la próxima.
      if (pushHistoryId) await updateHistory(admin, userId, pushHistoryId)
      return ok()
    }

    const accessToken = await refreshAccessToken(conn.refresh_token as string)
    const ids = await listAddedMessageIds(accessToken, startHistoryId)

    // Avanzar el history_id aunque no haya nada que insertar.
    const newHistory = pushHistoryId ?? startHistoryId

    if (ids.length === 0) {
      await updateHistory(admin, userId, newHistory)
      return ok()
    }

    // Reglas + tarjetas del usuario para el parseo.
    const { data: rules } = await admin
      .from('parsing_rules')
      .select('bank_name, config')
      .eq('user_id', userId)
      .eq('channel', 'email')
    const ruleList = (rules ?? []) as EmailRule[]

    // Sin remitentes configurados no hay nada que capturar. history.list no
    // acepta filtro `from:`, así que aquí llega TODO el buzón (incluidas
    // Promociones y Social): sin reglas, avanzar y salir sin tocar nada.
    if (ruleList.length === 0) {
      await updateHistory(admin, userId, newHistory)
      return ok()
    }

    const { data: cardsData } = await admin
      .from('cards')
      .select('id, last4, type, account_id')
      .eq('user_id', userId)
    const cards: CardRow[] = (cardsData ?? []) as CardRow[]

    const staged: Record<string, unknown>[] = []
    for (const id of ids) {
      const msg = await getMessage(accessToken, id)
      if (!msg) continue
      const tx = await stageFromGmailMessage(msg, {
        userId,
        rules: ruleList,
        cards,
        defaultAccountId: null,
        getAttachment: (attId) => getAttachmentData(accessToken, id, attId),
      })
      if (tx) staged.push(tx)
    }

    if (staged.length > 0) {
      const extIds = staged.map((s) => s.external_id as string)
      const { data: existing } = await admin
        .from('transactions')
        .select('external_id')
        .eq('user_id', userId)
        .in('external_id', extIds)
      const seen = new Set((existing ?? []).map((r: any) => r.external_id))
      const fresh = staged.filter((s) => !seen.has(s.external_id as string))
      if (fresh.length > 0) {
        const { error: insErr } = await admin.from('transactions').insert(fresh)
        if (insErr) throw insErr
      }
    }

    await updateHistory(admin, userId, newHistory)
    return ok()
  } catch (error) {
    console.error('gmail-push error:', error)
    // Responder 200 igualmente para no forzar reintentos infinitos de Pub/Sub
    // en errores no transitorios; los transitorios se recuperan al siguiente push.
    return ok()
  }
})

async function updateHistory(
  admin: ReturnType<typeof createClient>,
  userId: string,
  historyId: string,
) {
  await admin
    .from('gmail_connections')
    .update({ history_id: historyId, updated_at: new Date().toISOString() })
    .eq('user_id', userId)
}

function ok(): Response {
  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}
