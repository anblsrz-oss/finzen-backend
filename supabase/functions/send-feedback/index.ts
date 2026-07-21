// Recibe un comentario/sugerencia desde la landing pública y lo reenvía al
// correo del admin vía Resend. Se llama SIN sesión (usuarios no autenticados),
// por lo que debe desplegarse con verify_jwt=false.
//
// Secrets requeridos: RESEND_API_KEY
// Opcionales: RESEND_FROM_EMAIL (por defecto onboarding@resend.dev),
//   FEEDBACK_TO_EMAIL (destino; por defecto anbl.srz@gmail.com)
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') ?? 'Ahorbit <onboarding@resend.dev>'
const TO_EMAIL = Deno.env.get('FEEDBACK_TO_EMAIL') ?? 'anbl.srz@gmail.com'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST',
  // supabase-js (functions.invoke) agrega x-client-info y apikey automáticamente.
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  try {
    if (!RESEND_API_KEY) return json({ error: 'RESEND_API_KEY no configurado' }, 500)

    const { name, email, message } = await req.json().catch(() => ({}))
    const text = typeof message === 'string' ? message.trim() : ''
    if (!text) return json({ error: 'El mensaje es requerido' }, 400)
    if (text.length > 5000) return json({ error: 'Mensaje demasiado largo' }, 400)

    const fromName = (typeof name === 'string' && name.trim()) || 'Anónimo'
    const fromEmail = (typeof email === 'string' && email.trim()) || 'sin correo'

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: FROM_EMAIL,
        to: [TO_EMAIL],
        reply_to: typeof email === 'string' && email.includes('@') ? email : undefined,
        subject: `💬 Comentario en Ahorbit — ${escapeHtml(fromName)}`,
        html: `
          <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto;">
            <h2>💬 Nuevo comentario en Ahorbit</h2>
            <p><strong>De:</strong> ${escapeHtml(fromName)} (${escapeHtml(fromEmail)})</p>
            <p style="white-space: pre-wrap; background:#f8fafc; padding:12px;
                      border-radius:8px; color:#0f172a;">${escapeHtml(text)}</p>
          </div>
        `,
      }),
    })

    if (!res.ok) {
      const errBody = await res.text()
      console.error('Resend error:', errBody)
      return json({ error: 'No se pudo enviar el comentario' }, 502)
    }

    return json({ sent: true })
  } catch (error) {
    console.error('send-feedback error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})
