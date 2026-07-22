import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Sincroniza movimientos desde los correos del propio usuario: alertas del
// banco y correos de proveedores (facturas, tickets, domiciliados). El cliente
// envía su `providerToken` de Google (scope gmail.readonly). Aquí se consulta
// Gmail API, se parsea con las reglas del usuario (parsing_rules channel='email')
// y se insertan transacciones PENDIENTES (source='email', pending=true) para
// que el usuario confirme.
//
// Requisitos de OAuth (ver src/lib/emailSync.ts y NATIVE_SETUP.md):
//   scope: https://www.googleapis.com/auth/gmail.readonly

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}

interface EmailRuleConfig {
  senders?: string[]
  amountRegex?: string
  dateRegex?: string
  conceptRegex?: string
  // Moneda fija o regex que la extrae (grupo 1). Si no hay ninguna: MXN.
  currency?: string
  currencyRegex?: string
  // Tipo de movimiento a crear. Por defecto 'expense'.
  kind?: 'income' | 'expense'
  // Regex que extrae la terminación (4 dígitos) de la tarjeta del correo.
  last4Regex?: string
}

interface CardRow {
  id: string
  last4: string | null
  type: string
  account_id: string | null
}

// Terminación de tarjeta genérica cuando la regla no define last4Regex. Exige
// palabras de contexto o máscara para no confundirse con otros números.
const GENERIC_LAST4 =
  /(?:terminaci[oó]n|terminada en|final(?:iza)?(?:\s+en)?|\*{2,}|·{2,}|x{2,})\s*(\d{4})/i

function djb2(str: string): string {
  let h = 5381
  for (let i = 0; i < str.length; i++) h = (h * 33) ^ str.charCodeAt(i)
  return 'eml_' + (h >>> 0).toString(16)
}

function decodeB64Url(data: string): string {
  const b64 = data.replace(/-/g, '+').replace(/_/g, '/')
  try {
    return decodeURIComponent(escape(atob(b64)))
  } catch {
    return atob(b64)
  }
}

function extractBody(payload: any): string {
  if (!payload) return ''
  if (payload.body?.data) return decodeB64Url(payload.body.data)
  if (Array.isArray(payload.parts)) {
    return payload.parts.map(extractBody).join('\n')
  }
  return ''
}

// Recolecta los attachmentId de las partes XML (facturas CFDI adjuntas).
function collectXmlAttachments(payload: any, out: string[] = []): string[] {
  if (!payload) return out
  const mt = (payload.mimeType ?? '').toLowerCase()
  const fn = (payload.filename ?? '').toLowerCase()
  if (payload.body?.attachmentId && (mt.includes('xml') || fn.endsWith('.xml'))) {
    out.push(payload.body.attachmentId)
  }
  if (Array.isArray(payload.parts)) {
    for (const p of payload.parts) collectXmlAttachments(p, out)
  }
  return out
}

// Extrae datos de un CFDI por regex (Deno no tiene DOMParser). El XML es
// estructurado, así que es confiable. Total="" es del Comprobante (los
// conceptos usan Importe=""), no se confunde.
function parseCfdiString(xml: string): {
  amount: number | null
  date: string | null
  emisor: string | null
  currency: string | null
  isIncome: boolean
} {
  const total = xml.match(/\bTotal="([\d.]+)"/)?.[1]
  const fecha = xml.match(/\bFecha="([0-9T:\-]+)"/)?.[1]
  const moneda = xml.match(/\bMoneda="([A-Z]{3})"/)?.[1]
  const emisor = xml.match(/<[\w:]*Emisor\b[^>]*\bNombre="([^"]*)"/i)?.[1]
  // TipoDeComprobante: N = nómina, que el patrón emite al trabajador. Para
  // quien recibe el CFDI es un INGRESO, no un gasto.
  const tipo = xml.match(/\bTipoDeComprobante="([A-Z])"/i)?.[1]
  const amount = total ? parseFloat(total) : null
  return {
    amount: amount != null && Number.isFinite(amount) && amount > 0 ? amount : null,
    date: fecha ? fecha.slice(0, 10) : null,
    emisor: emisor ?? null,
    currency: moneda && /^[A-Z]{3}$/.test(moneda) ? moneda : null,
    isIncome: (tipo ?? '').toUpperCase() === 'N',
  }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  try {
    const authHeader = req.headers.get('authorization')
    if (!authHeader) {
      return json({ error: 'No authorization header' }, 401)
    }

    // Cliente con el JWT del usuario => la RLS valida user_id = auth.uid().
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

    // Reglas de parseo de correo del usuario.
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

    // Tarjetas del usuario, para resolver la terminación (last4) del correo.
    const { data: cardsData } = await supabase
      .from('cards')
      .select('id, last4, type, account_id')
      .eq('user_id', userId)
    const cards: CardRow[] = (cardsData ?? []) as CardRow[]
    const resolveCard = (last4: string | null): CardRow | null => {
      if (!last4) return null
      return cards.find((c) => c.last4 && c.last4 === last4) ?? null
    }

    const senders = rules
      .flatMap((r: any) => (r.config as EmailRuleConfig).senders ?? [])
      .filter(Boolean)
    const fromClause =
      senders.length > 0 ? `from:(${senders.join(' OR ')}) ` : ''
    const q = `${fromClause}newer_than:${sinceDays}d`

    // 1) Listar mensajes.
    const listRes = await fetch(
      `https://gmail.googleapis.com/gmail/v1/users/me/messages?q=${encodeURIComponent(q)}&maxResults=100`,
      { headers: { Authorization: `Bearer ${providerToken}` } },
    )
    if (!listRes.ok) {
      return json({ error: `Gmail list falló: ${listRes.status}` }, 502)
    }
    const list = await listRes.json()
    const ids: string[] = (list.messages ?? []).map((m: any) => m.id)

    // 2) Procesar cada mensaje.
    const staged: any[] = []
    for (const id of ids) {
      const msgRes = await fetch(
        `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}?format=full`,
        { headers: { Authorization: `Bearer ${providerToken}` } },
      )
      if (!msgRes.ok) continue
      const msg = await msgRes.json()
      const headers: any[] = msg.payload?.headers ?? []
      const from = (headers.find((h) => h.name === 'From')?.value ?? '').toLowerCase()
      const subject = headers.find((h) => h.name === 'Subject')?.value ?? ''
      const text = `${subject}\n${extractBody(msg.payload)}\n${msg.snippet ?? ''}`

      // 2a) Factura CFDI adjunta (XML): extracción exacta, preferida sobre el
      // regex del cuerpo. Cubre "cuando llega la factura por correo".
      let cfdiStaged = false
      for (const attId of collectXmlAttachments(msg.payload)) {
        const attRes = await fetch(
          `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}/attachments/${attId}`,
          { headers: { Authorization: `Bearer ${providerToken}` } },
        )
        if (!attRes.ok) continue
        const attJson = await attRes.json()
        if (!attJson.data) continue
        const cfdi = parseCfdiString(decodeB64Url(attJson.data))
        if (cfdi.amount) {
          staged.push({
            user_id: userId,
            kind: cfdi.isIncome ? 'income' : 'expense',
            amount: cfdi.amount,
            currency: cfdi.currency ?? 'MXN',
            concept: (cfdi.emisor ?? subject).slice(0, 200),
            account_id: defaultAccountId,
            card_id: null,
            tx_date:
              cfdi.date ??
              new Date(parseInt(msg.internalDate, 10)).toISOString().slice(0, 10),
            source: 'email',
            external_id: djb2(id),
            pending: true,
          })
          cfdiStaged = true
          break
        }
      }
      if (cfdiStaged) continue

      // Elegir la regla cuyo remitente aparece en el From.
      const rule = rules.find((r: any) => {
        const cfg = r.config as EmailRuleConfig
        return (cfg.senders ?? []).some((s) => from.includes(s.toLowerCase()))
      })
      const cfg: EmailRuleConfig = (rule?.config as EmailRuleConfig) ?? {}

      const amountRe = cfg.amountRegex
        ? new RegExp(cfg.amountRegex, 'i')
        : /\$?\s?([\d,]+\.\d{2})/
      const amountMatch = text.match(amountRe)
      if (!amountMatch) continue
      const amount = parseFloat(amountMatch[1].replace(/,/g, ''))
      if (!Number.isFinite(amount) || amount <= 0) continue

      const concept = cfg.conceptRegex
        ? text.match(new RegExp(cfg.conceptRegex, 'i'))?.[1] ?? subject
        : subject

      // Moneda: fija de la regla, regex de la regla, o MXN por compatibilidad.
      let currency = 'MXN'
      if (cfg.currency && /^[A-Za-z]{3}$/.test(cfg.currency)) {
        currency = cfg.currency.toUpperCase()
      } else if (cfg.currencyRegex) {
        const m = text.match(new RegExp(cfg.currencyRegex, 'i'))?.[1]
        if (m && /^[A-Za-z]{3}$/.test(m)) currency = m.toUpperCase()
      }

      const kind: 'income' | 'expense' = cfg.kind === 'income' ? 'income' : 'expense'

      // Terminación de tarjeta: regex de la regla o patrón genérico. Si coincide
      // una tarjeta del usuario, se asigna esa tarjeta (y su cuenta si aplica).
      const last4 = cfg.last4Regex
        ? text.match(new RegExp(cfg.last4Regex, 'i'))?.[1] ?? null
        : text.match(GENERIC_LAST4)?.[1] ?? null
      const card = resolveCard(last4)
      // Crédito no toca cuenta; débito/vale descuentan de su cuenta ligada.
      const accountId = card
        ? card.type === 'credit'
          ? null
          : card.account_id
        : defaultAccountId

      staged.push({
        user_id: userId,
        kind,
        amount,
        currency,
        concept: concept.slice(0, 200),
        account_id: accountId,
        card_id: card?.id ?? null,
        tx_date: new Date(parseInt(msg.internalDate, 10)).toISOString().slice(0, 10),
        source: 'email',
        external_id: djb2(id),
        pending: true,
      })
    }

    if (staged.length === 0) return json({ inserted: 0, found: ids.length })

    // 3) Dedupe contra transactions existentes.
    const extIds = staged.map((s) => s.external_id)
    const { data: existing } = await supabase
      .from('transactions')
      .select('external_id')
      .in('external_id', extIds)
    const seen = new Set((existing ?? []).map((r: any) => r.external_id))
    const fresh = staged.filter((s) => !seen.has(s.external_id))

    if (fresh.length > 0) {
      const { error: insErr } = await supabase.from('transactions').insert(fresh)
      if (insErr) throw insErr
    }

    return json({ inserted: fresh.length, found: ids.length, duplicates: staged.length - fresh.length })
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
