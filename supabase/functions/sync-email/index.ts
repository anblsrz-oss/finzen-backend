import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  stageFromGmailMessage,
  type CardRow,
  type EmailRule,
} from '../_shared/parseEmail.ts'

// Sincroniza movimientos desde los correos del propio usuario: alertas del
// banco y correos de proveedores (facturas, tickets, domiciliados). El cliente
// envía su `providerToken` de Google (scope gmail.readonly). Aquí se consulta
// Gmail API, se parsea con las reglas del usuario (parsing_rules channel='email')
// y se insertan transacciones PENDIENTES (source='email', pending=true).
//
// El parseo vive en ../_shared/parseEmail.ts (compartido con gmail-push).
//   scope: https://www.googleapis.com/auth/gmail.readonly

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  try {
    const authHeader = req.headers.get('authorization')
    if (!authHeader) return json({ error: 'No authorization header' }, 401)

    const supabase = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    })

    const { data: userData, error: authErr } = await supabase.auth.getUser()
    if (authErr || !userData.user) return json({ error: 'Unauthorized' }, 401)
    const userId = userData.user.id

    const body = await req.json().catch(() => ({}))
    const providerToken: string | undefined = body.providerToken
    const sinceDays: number = Math.min(Math.max(body.sinceDays ?? 30, 1), 365)
    const defaultAccountId: string | null = body.accountId ?? null
    if (!providerToken) return json({ error: 'Falta providerToken de Google' }, 400)

    const { data: rules, error: rulesErr } = await supabase
      .from('parsing_rules')
      .select('*')
      .eq('user_id', userId)
      .eq('channel', 'email')
    if (rulesErr) throw rulesErr
    if (!rules || rules.length === 0) {
      return json(
        {
          error:
            'No hay reglas de correo configuradas. Crea una regla por remitente (banco o proveedor) primero.',
        },
        400,
      )
    }

    const { data: cardsData } = await supabase
      .from('cards')
      .select('id, last4, type, account_id')
      .eq('user_id', userId)
    const cards: CardRow[] = (cardsData ?? []) as CardRow[]
    const ruleList = rules as EmailRule[]

    // Construir la query de Gmail por remitentes.
    const senders = ruleList
      .flatMap((r) => r.config.senders ?? [])
      .filter(Boolean)
    const fromClause = senders.length > 0 ? `from:(${senders.join(' OR ')}) ` : ''
    const q = `${fromClause}newer_than:${sinceDays}d`

    const authGet = (u: string) =>
      fetch(u, { headers: { Authorization: `Bearer ${providerToken}` } })

    const listRes = await authGet(
      `https://gmail.googleapis.com/gmail/v1/users/me/messages?q=${encodeURIComponent(q)}&maxResults=100`,
    )
    if (!listRes.ok) {
      const detail = await listRes.text().catch(() => '')
      console.error('Gmail list error', listRes.status, detail)
      return json({ error: `Gmail list falló: ${listRes.status} ${detail.slice(0, 400)}` }, 502)
    }
    const list = await listRes.json()
    const ids: string[] = (list.messages ?? []).map((m: any) => m.id)

    const staged: Record<string, unknown>[] = []
    for (const id of ids) {
      const msgRes = await authGet(
        `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}?format=full`,
      )
      if (!msgRes.ok) continue
      const msg = await msgRes.json()
      const tx = await stageFromGmailMessage(msg, {
        userId,
        rules: ruleList,
        cards,
        defaultAccountId,
        getAttachment: async (attId) => {
          const r = await authGet(
            `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}/attachments/${attId}`,
          )
          if (!r.ok) return null
          const j = await r.json()
          return j.data ?? null
        },
      })
      if (tx) staged.push(tx)
    }

    if (staged.length === 0) return json({ inserted: 0, found: ids.length })

    const extIds = staged.map((s) => s.external_id as string)
    const { data: existing } = await supabase
      .from('transactions')
      .select('external_id')
      .in('external_id', extIds)
    const seen = new Set((existing ?? []).map((r: any) => r.external_id))
    const fresh = staged.filter((s) => !seen.has(s.external_id as string))

    if (fresh.length > 0) {
      const { error: insErr } = await supabase.from('transactions').insert(fresh)
      if (insErr) throw insErr
    }

    return json({
      inserted: fresh.length,
      found: ids.length,
      duplicates: staged.length - fresh.length,
    })
  } catch (error) {
    console.error('sync-email error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  })
}
