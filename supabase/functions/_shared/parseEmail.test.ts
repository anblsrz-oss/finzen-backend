// Tests del parseo compartido de correos. El módulo no tiene dependencias
// externas, así que corre igual bajo Deno (producción) y bajo el runner nativo
// de Node:  node --test supabase/functions/_shared/parseEmail.test.ts
import test from 'node:test'
import assert from 'node:assert/strict'
import { stageFromGmailMessage, extractBody, type EmailRule, type StageOpts } from './parseEmail.ts'

// --- helpers de fixtures -------------------------------------------------

const b64 = (s: string) => Buffer.from(s, 'utf8').toString('base64url')

function part(mimeType: string, body: string, extra: Record<string, unknown> = {}) {
  return { mimeType, body: { data: b64(body) }, ...extra }
}

function message(opts: {
  from: string
  subject: string
  payload?: any
  snippet?: string
  id?: string
}) {
  return {
    id: opts.id ?? 'msg-1',
    internalDate: String(Date.UTC(2026, 6, 30)),
    snippet: opts.snippet ?? '',
    payload: {
      mimeType: 'text/plain',
      headers: [
        { name: 'From', value: opts.from },
        { name: 'Subject', value: opts.subject },
      ],
      ...(opts.payload ?? { body: { data: b64('') } }),
    },
  }
}

const BBVA_RULE: EmailRule = {
  bank_name: 'BBVA',
  config: { senders: ['notificaciones@bbva.mx'], kind: 'expense' },
}

function opts(rules: EmailRule[] = [BBVA_RULE], over: Partial<StageOpts> = {}): StageOpts {
  return {
    userId: 'user-1',
    rules,
    cards: [],
    defaultAccountId: null,
    getAttachment: async () => null,
    ...over,
  }
}

// --- 1. Remitente no configurado: nunca se registra ----------------------

test('descarta correo de remitente no configurado con números en el CSS', async () => {
  // Reproducción directa del bug: "Compartiste algunos datos de tu Cuenta de
  // Google con Claude" se registró como -$0.25 por el line-height del HTML.
  const msg = message({
    from: 'Google <no-reply@accounts.google.com>',
    subject: 'Compartiste algunos datos de tu Cuenta de Google con Claude',
    payload: part(
      'text/html',
      '<html><head><style>body{line-height:1.25;margin:0.05em}</style></head>' +
        '<body><p>Revisa la actividad de tu cuenta.</p></body></html>',
    ),
  })
  assert.equal(await stageFromGmailMessage(msg, opts()), null)
})

test('descarta oferta de empleo con un monto real en el cuerpo', async () => {
  // "seleccionamos para ti vacantes en Ciudad de México" se registró como
  // -$87,000.00, que era el rango salarial del anuncio.
  const msg = message({
    from: 'LinkedIn <jobs-noreply@linkedin.com>',
    subject: 'Alexander Aníbal Suárez Alcántara seleccionamos para ti vacantes',
    payload: part('text/plain', 'Gerente de Finanzas — sueldo de $87,000.00 mensuales.'),
  })
  assert.equal(await stageFromGmailMessage(msg, opts()), null)
})

test('descarta correo cuando el usuario no tiene ninguna regla', async () => {
  const msg = message({
    from: 'noreply@whatsapp.com',
    subject: 'Angie envió un mensaje al chat de grupo',
    payload: part('text/plain', 'Tienes 1 mensaje nuevo. $0.05'),
  })
  assert.equal(await stageFromGmailMessage(msg, opts([])), null)
})

// --- 2. Remitente configurado: sí se registra ---------------------------

test('registra la alerta de un remitente configurado', async () => {
  const msg = message({
    from: 'BBVA <notificaciones@bbva.mx>',
    subject: 'Alerta de cargo',
    payload: part(
      'text/plain',
      'Se realizó un cargo por $1,234.56 en AMAZON MX con tu tarjeta terminada en 4321.',
    ),
  })
  const tx = await stageFromGmailMessage(msg, opts())
  assert.ok(tx)
  assert.equal(tx.amount, 1234.56)
  assert.equal(tx.kind, 'expense')
  assert.equal(tx.currency, 'MXN')
  assert.equal(tx.concept, 'Alerta de cargo')
  assert.equal(tx.pending, true)
  assert.equal(tx.source, 'email')
})

test('prefiere el monto pegado al símbolo de moneda, no el primer número', async () => {
  const msg = message({
    from: 'notificaciones@bbva.mx',
    subject: 'Alerta de cargo',
    payload: part('text/plain', 'Folio 99.10 · aviso v2.05\nCargo por $1,234.56 en OXXO.'),
  })
  const tx = await stageFromGmailMessage(msg, opts())
  assert.ok(tx)
  assert.equal(tx.amount, 1234.56)
})

test('acepta el monto con la moneda pospuesta', async () => {
  const msg = message({
    from: 'notificaciones@bbva.mx',
    subject: 'Alerta',
    payload: part('text/plain', 'Compra por 2,500.00 MXN en CFE.'),
  })
  const tx = await stageFromGmailMessage(msg, opts())
  assert.ok(tx)
  assert.equal(tx.amount, 2500)
})

test('un remitente configurado por dominio también coincide', async () => {
  const rule: EmailRule = { bank_name: 'BBVA', config: { senders: ['@bbva.mx'] } }
  const msg = message({
    from: 'Avisos BBVA <alertas@bbva.mx>',
    subject: 'Cargo',
    payload: part('text/plain', 'Cargo por $100.00'),
  })
  const tx = await stageFromGmailMessage(msg, opts([rule]))
  assert.ok(tx)
  assert.equal(tx.amount, 100)
})

test('descarta el correo de un remitente configurado que no trae monto', async () => {
  const msg = message({
    from: 'notificaciones@bbva.mx',
    subject: 'Tu estado de cuenta ya está disponible',
    payload: part('text/plain', 'Consulta tu estado de cuenta en la app.'),
  })
  assert.equal(await stageFromGmailMessage(msg, opts()), null)
})

// --- 3. CFDI adjunto: se sigue aceptando sin regla ----------------------

test('registra una factura CFDI aunque el remitente no esté configurado', async () => {
  const xml =
    '<cfdi:Comprobante Total="4321.00" Fecha="2026-07-15T10:00:00" Moneda="MXN" TipoDeComprobante="I">' +
    '<cfdi:Emisor Nombre="TOTAL PLAY TELECOMUNICACIONES" /></cfdi:Comprobante>'
  const msg = message({
    from: 'facturacion@proveedor-desconocido.com',
    subject: 'Tu factura',
    payload: {
      mimeType: 'multipart/mixed',
      parts: [
        part('text/plain', 'Adjuntamos tu factura.'),
        { mimeType: 'application/xml', filename: 'factura.xml', body: { attachmentId: 'att-1' } },
      ],
    },
  })
  const tx = await stageFromGmailMessage(
    msg,
    opts([], { getAttachment: async () => b64(xml) }),
  )
  assert.ok(tx)
  assert.equal(tx.amount, 4321)
  assert.equal(tx.kind, 'expense')
  assert.equal(tx.concept, 'TOTAL PLAY TELECOMUNICACIONES')
  assert.equal(tx.tx_date, '2026-07-15')
})

// --- 4. extractBody: texto plano, no markup -----------------------------

test('extractBody prefiere la parte text/plain', () => {
  const payload = {
    mimeType: 'multipart/alternative',
    parts: [
      part('text/plain', 'Cargo por $10.00'),
      part('text/html', '<style>p{line-height:1.25}</style><p>Cargo por $10.00</p>'),
    ],
  }
  const body = extractBody(payload)
  assert.equal(body.trim(), 'Cargo por $10.00')
  assert.ok(!body.includes('line-height'))
})

test('extractBody limpia el HTML cuando no hay text/plain', () => {
  const payload = part(
    'text/html',
    '<html><head><style>body{line-height:1.25}</style>' +
      '<script>var t=0.05;</script></head><body><p>Cargo&nbsp;por $10.00</p></body></html>',
  )
  const body = extractBody(payload)
  assert.ok(!body.includes('line-height'), 'no debe conservar CSS')
  assert.ok(!body.includes('var t'), 'no debe conservar JS')
  assert.ok(!body.includes('<'), 'no debe conservar etiquetas')
  assert.ok(body.includes('Cargo por $10.00'), 'debe conservar el texto y decodificar &nbsp;')
})

test('extractBody ignora los adjuntos', () => {
  const payload = {
    mimeType: 'multipart/mixed',
    parts: [
      part('text/plain', 'Adjuntamos tu factura.'),
      part('text/plain', 'Total="99.99"', { filename: 'factura.xml' }),
    ],
  }
  assert.ok(!extractBody(payload).includes('99.99'))
})
