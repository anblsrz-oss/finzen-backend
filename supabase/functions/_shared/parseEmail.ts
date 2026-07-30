// Parseo compartido de correos de Gmail a transacciones pendientes.
// Lo usan `sync-email` (pull manual con el token del cliente) y `gmail-push`
// (webhook en tiempo real con el refresh token guardado). Una sola implementación
// para no divergir.

export interface EmailRuleConfig {
  senders?: string[]
  amountRegex?: string
  dateRegex?: string
  conceptRegex?: string
  currency?: string
  currencyRegex?: string
  kind?: 'income' | 'expense'
  last4Regex?: string
}

export interface CardRow {
  id: string
  last4: string | null
  type: string
  account_id: string | null
}

export interface EmailRule {
  bank_name?: string
  config: EmailRuleConfig
}

// Terminación de tarjeta genérica cuando la regla no define last4Regex.
const GENERIC_LAST4 =
  /(?:terminaci[oó]n|terminada en|final(?:iza)?(?:\s+en)?|\*{2,}|·{2,}|x{2,})\s*(\d{4})/i

export function djb2(str: string): string {
  let h = 5381
  for (let i = 0; i < str.length; i++) h = (h * 33) ^ str.charCodeAt(i)
  return 'eml_' + (h >>> 0).toString(16)
}

export function decodeB64Url(data: string): string {
  const b64 = data.replace(/-/g, '+').replace(/_/g, '/')
  try {
    return decodeURIComponent(escape(atob(b64)))
  } catch {
    return atob(b64)
  }
}

const NAMED_ENTITIES: Record<string, string> = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
}

// Deja solo el texto legible del HTML. Sin esto el CSS y el JS del correo
// (line-height:1.25, margin:0.05em) entran al buscador de montos y producen
// transacciones fantasma.
export function stripHtml(html: string): string {
  return html
    .replace(/<(style|script)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<br\s*\/?>|<\/(?:p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
    .replace(/&(?:nbsp|amp|lt|gt|quot|apos);/gi, (m) => NAMED_ENTITIES[m.toLowerCase()] ?? m)
    .replace(/[ \t ]+/g, ' ')
    .replace(/\n[ \n]*\n+/g, '\n')
    .trim()
}

// Primera parte MIME del tipo pedido, ignorando adjuntos.
function findPart(payload: any, mimeType: string): string | null {
  if (!payload || payload.filename) return null
  const mt = (payload.mimeType ?? '').toLowerCase()
  if (mt.startsWith(mimeType) && payload.body?.data) {
    return decodeB64Url(payload.body.data)
  }
  if (Array.isArray(payload.parts)) {
    for (const p of payload.parts) {
      const found = findPart(p, mimeType)
      if (found) return found
    }
  }
  return null
}

// Cuerpo legible del correo: se prefiere text/plain y, si no existe, se limpia
// el text/html. Nunca se devuelve markup crudo.
export function extractBody(payload: any): string {
  if (!payload) return ''
  const plain = findPart(payload, 'text/plain')
  if (plain) return plain
  const html = findPart(payload, 'text/html')
  return html ? stripHtml(html) : ''
}

export function collectXmlAttachments(payload: any, out: string[] = []): string[] {
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

export function parseCfdiString(xml: string): {
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

// Monto pegado a un símbolo o código de moneda, antes o después de la cifra.
const CURRENCY_AMOUNT =
  /(?:\$|\bMXN\b|\bUSD\b|\bEUR\b)\s*([\d,]+(?:\.\d{2})?)|([\d,]+(?:\.\d{2})?)\s*(?:\bMXN\b|\bUSD\b|\bEUR\b)/i
// Respaldo para bancos que omiten la moneda: cualquier cifra con dos decimales.
const LOOSE_AMOUNT = /([\d,]+\.\d{2})/

// Primer monto válido del texto. Se prefiere el que va junto a una moneda para
// no quedarse con un folio o un número de versión que aparezca antes.
function matchAmount(text: string, cfg: EmailRuleConfig): number | null {
  const patterns = cfg.amountRegex
    ? [new RegExp(cfg.amountRegex, 'i')]
    : [CURRENCY_AMOUNT, LOOSE_AMOUNT]
  for (const re of patterns) {
    const raw = text.match(re)?.slice(1).find((g) => g != null)
    if (!raw) continue
    const n = parseFloat(raw.replace(/,/g, ''))
    if (Number.isFinite(n) && n > 0) return n
  }
  return null
}

export function resolveCard(cards: CardRow[], last4: string | null): CardRow | null {
  if (!last4) return null
  return cards.find((c) => c.last4 && c.last4 === last4) ?? null
}

export interface StageOpts {
  userId: string
  rules: EmailRule[]
  cards: CardRow[]
  defaultAccountId: string | null
  // Descarga el contenido base64 de un adjunto por su attachmentId.
  getAttachment: (attachmentId: string) => Promise<string | null>
}

// Convierte UN mensaje completo de Gmail (formato full) en una transacción
// pendiente lista para insertar, o null si no aplica. Prioriza el CFDI adjunto.
export async function stageFromGmailMessage(
  msg: any,
  opts: StageOpts,
): Promise<Record<string, unknown> | null> {
  const { userId, rules, cards, defaultAccountId, getAttachment } = opts
  const id: string = msg.id
  const headers: any[] = msg.payload?.headers ?? []
  const from = (headers.find((h) => h.name === 'From')?.value ?? '').toLowerCase()
  const subject = headers.find((h) => h.name === 'Subject')?.value ?? ''
  const text = `${subject}\n${extractBody(msg.payload)}\n${msg.snippet ?? ''}`
  const internalDate = () =>
    new Date(parseInt(msg.internalDate, 10)).toISOString().slice(0, 10)

  // 1) Factura CFDI adjunta (XML): extracción exacta, preferida.
  for (const attId of collectXmlAttachments(msg.payload)) {
    const data = await getAttachment(attId)
    if (!data) continue
    const cfdi = parseCfdiString(decodeB64Url(data))
    if (cfdi.amount) {
      return {
        user_id: userId,
        kind: cfdi.isIncome ? 'income' : 'expense',
        amount: cfdi.amount,
        currency: cfdi.currency ?? 'MXN',
        concept: (cfdi.emisor ?? subject).slice(0, 200),
        account_id: defaultAccountId,
        card_id: null,
        tx_date: cfdi.date ?? internalDate(),
        source: 'email',
        external_id: djb2(id),
        pending: true,
      }
    }
  }

  // 2) Regla por remitente + regex. El remitente es OBLIGATORIO: si el correo
  //    no viene de uno configurado no se registra nada. Sin este corte, cualquier
  //    correo del buzón con un número de dos decimales acababa como egreso.
  const rule = rules.find((r) =>
    (r.config.senders ?? []).some((s) => from.includes(s.toLowerCase())),
  )
  if (!rule) return null
  const cfg: EmailRuleConfig = rule.config

  const amount = matchAmount(text, cfg)
  if (amount == null) return null

  const concept = cfg.conceptRegex
    ? text.match(new RegExp(cfg.conceptRegex, 'i'))?.[1] ?? subject
    : subject

  let currency = 'MXN'
  if (cfg.currency && /^[A-Za-z]{3}$/.test(cfg.currency)) {
    currency = cfg.currency.toUpperCase()
  } else if (cfg.currencyRegex) {
    const m = text.match(new RegExp(cfg.currencyRegex, 'i'))?.[1]
    if (m && /^[A-Za-z]{3}$/.test(m)) currency = m.toUpperCase()
  }

  const kind: 'income' | 'expense' = cfg.kind === 'income' ? 'income' : 'expense'

  const last4 = cfg.last4Regex
    ? text.match(new RegExp(cfg.last4Regex, 'i'))?.[1] ?? null
    : text.match(GENERIC_LAST4)?.[1] ?? null
  const card = resolveCard(cards, last4)
  const accountId = card
    ? card.type === 'credit'
      ? null
      : card.account_id
    : defaultAccountId

  return {
    user_id: userId,
    kind,
    amount,
    currency,
    concept: concept.slice(0, 200),
    account_id: accountId,
    card_id: card?.id ?? null,
    tx_date: internalDate(),
    source: 'email',
    external_id: djb2(id),
    pending: true,
  }
}
