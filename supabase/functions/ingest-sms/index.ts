import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Ingesta de SMS bancarios en tiempo real. La llama el receptor nativo de
// Android (app abierta o CERRADA) y también el fallback de lectura de inbox del
// cliente. Como el receptor no tiene sesión JWT viva, autentica con un TOKEN DE
// DISPOSITIVO (ver tabla sms_device_tokens); aquí se resuelve el token -> user.
// Se parsea con las reglas del usuario (parsing_rules channel='sms'), se detecta
// ingreso/gasto según el texto, se deduplica y se insertan transacciones
// PENDIENTES (source='sms', pending=true) para que el usuario confirme.
//
// Desplegar SIN verificación de JWT (la auth es por token de dispositivo):
//   supabase functions deploy ingest-sms --no-verify-jwt

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Palabras por defecto (español) para inferir la dirección del movimiento
// cuando la regla del banco no define las suyas.
const DEFAULT_INCOME = [
  'recibiste', 'recibió', 'recibio', 'abono', 'depósito', 'deposito',
  'te depositaron', 'spei recibido', 'transferencia recibida', 'te enviaron',
  'devolución', 'devolucion', 'reembolso', 'bonificación', 'bonificacion',
]
const DEFAULT_EXPENSE = [
  'compra', 'cargo', 'pago', 'retiro', 'disposición', 'disposicion',
  'enviaste', 'transferencia enviada', 'spei enviado', 'domiciliación', 'domiciliacion',
]

interface SmsRuleConfig {
  senders?: string[]
  amountRegex?: string
  conceptRegex?: string
  currency?: string
  currencyRegex?: string
  // Detección de dirección. Si el cuerpo hace match con incomeKeywords => income.
  incomeKeywords?: string[]
  expenseKeywords?: string[]
}

interface RawSms {
  address: string
  body: string
  date: number // epoch ms
}

// Mismo hash djb2 que src/lib/smsSync.ts para que native, fallback y esta
// función generen el MISMO external_id => dedupe consistente entre las 3 vías.
function djb2(str: string): string {
  let h = 5381
  for (let i = 0; i < str.length; i++) h = (h * 33) ^ str.charCodeAt(i)
  return 'sms_' + (h >>> 0).toString(16)
}

async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

// Fecha local del SMS. La app manda el offset (getTimezoneOffset, minutos a
// sumar al local para llegar a UTC; 360 = UTC-6). Sin él usamos UTC-6 (MX).
function localDate(epochMs: number, tzOffsetMin: number): string {
  return new Date(epochMs - tzOffsetMin * 60_000).toISOString().slice(0, 10)
}

// Quita acentos para que "depósito" y "deposito" matcheen igual.
function stripAccents(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '')
}

function buildKeywordRe(words: string[]): RegExp | null {
  const safe = words.map((w) => stripAccents(w.trim())).filter(Boolean)
    .map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  return safe.length ? new RegExp(`(?:${safe.join('|')})`, 'i') : null
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  try {
    const body = await req.json().catch(() => ({}))
    const token: string | undefined = body.token
    const tzOffsetMin: number = Number.isFinite(body.tzOffsetMinutes)
      ? body.tzOffsetMinutes
      : 360
    const messages: RawSms[] = Array.isArray(body.messages)
      ? body.messages
      : body.message
        ? [body.message]
        : []
    if (!token) return json({ error: 'Falta token de dispositivo' }, 401)
    if (messages.length === 0) return json({ found: 0, inserted: 0, duplicates: 0 })

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE)

    // 1) Resolver token de dispositivo -> user_id.
    const tokenHash = await sha256hex(token)
    const { data: device } = await supabase
      .from('sms_device_tokens')
      .select('id, user_id')
      .eq('token_hash', tokenHash)
      .maybeSingle()
    if (!device) return json({ error: 'Token de dispositivo inválido' }, 401)
    const userId = device.user_id as string

    // 2) Reglas de SMS del usuario.
    const { data: rules } = await supabase
      .from('parsing_rules')
      .select('bank_name, config')
      .eq('user_id', userId)
      .eq('channel', 'sms')
    const ruleList = (rules ?? []) as { bank_name: string; config: SmsRuleConfig }[]

    // 3) Parsear cada mensaje.
    const staged: Record<string, unknown>[] = []
    for (const m of messages) {
      const addr = (m.address ?? '').toLowerCase()
      const bodyText = m.body ?? ''
      if (!bodyText) continue

      const rule = ruleList.find((r) =>
        (r.config.senders ?? []).some((s) => addr.includes(s.toLowerCase())),
      )
      // Si hay reglas configuradas, solo procesar remitentes conocidos.
      if (ruleList.length > 0 && !rule) continue
      const cfg: SmsRuleConfig = rule?.config ?? {}

      const amountRe = cfg.amountRegex
        ? new RegExp(cfg.amountRegex, 'i')
        : /\$?\s?([\d,]+\.\d{2})/
      const match = bodyText.match(amountRe)
      if (!match) continue
      const amount = parseFloat(match[1].replace(/,/g, ''))
      if (!Number.isFinite(amount) || amount <= 0) continue

      // Dirección: ingreso si hace match con las palabras de ingreso.
      const incomeRe = buildKeywordRe(cfg.incomeKeywords ?? DEFAULT_INCOME)
      const kind: 'income' | 'expense' =
        incomeRe && incomeRe.test(stripAccents(bodyText)) ? 'income' : 'expense'

      let currency = 'MXN'
      if (cfg.currency && /^[A-Za-z]{3}$/.test(cfg.currency)) {
        currency = cfg.currency.toUpperCase()
      } else if (cfg.currencyRegex) {
        const c = bodyText.match(new RegExp(cfg.currencyRegex, 'i'))?.[1]
        if (c && /^[A-Za-z]{3}$/.test(c)) currency = c.toUpperCase()
      }

      const concept = cfg.conceptRegex
        ? bodyText.match(new RegExp(cfg.conceptRegex, 'i'))?.[1] ??
          (rule?.bank_name ?? 'SMS') + ': ' + bodyText.slice(0, 120)
        : (rule?.bank_name ?? 'SMS') + ': ' + bodyText.slice(0, 120)

      staged.push({
        user_id: userId,
        kind,
        amount,
        currency,
        concept: concept.slice(0, 200),
        account_id: null,
        tx_date: localDate(m.date, tzOffsetMin),
        source: 'sms',
        external_id: djb2(`${addr}|${m.date}|${bodyText}`),
        pending: true,
      })
    }

    if (staged.length === 0) {
      await touchDevice(supabase, device.id)
      return json({ found: messages.length, inserted: 0, duplicates: 0 })
    }

    // 4) Dedupe contra transactions existentes.
    const extIds = staged.map((s) => s.external_id as string)
    const { data: existing } = await supabase
      .from('transactions')
      .select('external_id')
      .eq('user_id', userId)
      .in('external_id', extIds)
    const seen = new Set((existing ?? []).map((r: { external_id: string }) => r.external_id))
    const fresh = staged.filter((s) => !seen.has(s.external_id as string))

    if (fresh.length > 0) {
      const { error: insErr } = await supabase.from('transactions').insert(fresh)
      if (insErr) throw insErr
    }
    await touchDevice(supabase, device.id)

    return json({
      found: messages.length,
      inserted: fresh.length,
      duplicates: staged.length - fresh.length,
    })
  } catch (error) {
    console.error('ingest-sms error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})

async function touchDevice(supabase: ReturnType<typeof createClient>, id: string) {
  await supabase
    .from('sms_device_tokens')
    .update({ last_used_at: new Date().toISOString() })
    .eq('id', id)
}

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  })
}
