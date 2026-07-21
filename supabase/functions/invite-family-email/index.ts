// Envía el correo de invitación al plan familiar vía Resend.
// Se invoca desde el cliente justo después de insertar la fila en
// family_members; si el correo falla, la invitación sigue existiendo en BD
// (el invitado también la ve al entrar a la app), así que este envío es
// "best effort", no la fuente de verdad.
//
// Secrets requeridos: RESEND_API_KEY
// Opcionales: RESEND_FROM_EMAIL (por defecto onboarding@resend.dev, solo
//   funciona en modo sandbox de Resend), APP_URL (por defecto https://finze.xyz)
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
)
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') ?? 'Ahorbit <onboarding@resend.dev>'
const APP_URL = Deno.env.get('APP_URL') ?? 'https://finze.xyz'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST',
  // supabase-js (functions.invoke) agrega x-client-info y apikey de forma
  // automática; hay que permitirlos o el navegador bloquea el preflight.
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  try {
    if (!RESEND_API_KEY) return json({ error: 'RESEND_API_KEY no configurado' }, 500)

    const authHeader = req.headers.get('authorization')
    if (!authHeader) return json({ error: 'No authorization header' }, 401)
    const token = authHeader.replace('Bearer ', '')
    const { data: userData, error: authError } = await supabase.auth.getUser(token)
    if (authError || !userData.user) return json({ error: 'Unauthorized' }, 401)

    const { familyId, email } = await req.json().catch(() => ({}))
    if (!familyId || !email) return json({ error: 'familyId y email son requeridos' }, 400)

    // Solo el dueño de la familia puede disparar el correo de esa familia.
    const { data: family } = await supabase
      .from('families')
      .select('name, owner_id')
      .eq('id', familyId)
      .single()
    if (!family || family.owner_id !== userData.user.id) {
      return json({ error: 'No eres el dueño de esta familia' }, 403)
    }

    const { data: ownerProfile } = await supabase
      .from('profiles')
      .select('full_name, email')
      .eq('id', userData.user.id)
      .single()
    const ownerName = ownerProfile?.full_name || ownerProfile?.email || 'Alguien'

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: FROM_EMAIL,
        to: [email],
        subject: `${ownerName} te invitó a su plan familiar en Ahorbit`,
        html: `
          <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto;">
            <h2>💰 Ahorbit</h2>
            <p><strong>${ownerName}</strong> te invitó a unirte al plan familiar
               "<strong>${family.name}</strong>" en Ahorbit.</p>
            <p>Podrás ver y registrar gastos en las tarjetas que comparta contigo,
               sin acceso a su límite de crédito.</p>
            <p>
              <a href="${APP_URL}/login"
                 style="display:inline-block;background:#0d9488;color:#fff;
                        padding:10px 20px;border-radius:8px;text-decoration:none;">
                Entrar con ${email}
              </a>
            </p>
            <p style="color:#64748b;font-size:12px;">
              Inicia sesión con Google usando este correo para ver la invitación.
            </p>
          </div>
        `,
      }),
    })

    if (!res.ok) {
      const errBody = await res.text()
      console.error('Resend error:', errBody)
      return json({ error: 'No se pudo enviar el correo' }, 502)
    }

    return json({ sent: true })
  } catch (error) {
    console.error('invite-family-email error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})
