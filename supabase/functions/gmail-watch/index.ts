import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { gmailWatch } from '../_shared/gmail.ts'

// Activa la captura de correo en tiempo real para el usuario: llama a
// users.watch (Gmail push -> Pub/Sub) y guarda en gmail_connections el
// refresh_token, el email, el history_id y la expiración del watch.
// La llama el cliente tras "Conectar Gmail" con access_token offline.
//
// Autenticada con el JWT del usuario (verifica identidad), pero escribe el
// refresh_token con service_role (el cliente no tiene permiso sobre esa columna).
//
// Secret requerido: GMAIL_PUBSUB_TOPIC (projects/<proj>/topics/<topic>)
//   supabase functions deploy gmail-watch

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const TOPIC = Deno.env.get('GMAIL_PUBSUB_TOPIC')!

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

    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: userData, error: authErr } = await userClient.auth.getUser()
    if (authErr || !userData.user) return json({ error: 'Unauthorized' }, 401)
    const userId = userData.user.id
    const email = userData.user.email ?? null

    const body = await req.json().catch(() => ({}))
    const accessToken: string | undefined = body.providerToken
    const refreshToken: string | undefined = body.providerRefreshToken
    if (!accessToken) return json({ error: 'Falta providerToken de Google' }, 400)

    // Activar el watch con el access token del usuario.
    const watch = await gmailWatch(accessToken, TOPIC)
    const expiration = watch.expiration
      ? new Date(parseInt(watch.expiration, 10)).toISOString()
      : null

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)
    // Upsert: si no llega refresh_token nuevo (Google solo lo da en el primer
    // consentimiento offline), conservamos el ya guardado.
    const row: Record<string, unknown> = {
      user_id: userId,
      email,
      history_id: watch.historyId,
      watch_expiration: expiration,
      updated_at: new Date().toISOString(),
    }
    if (refreshToken) row.refresh_token = refreshToken

    const { error: upErr } = await admin
      .from('gmail_connections')
      .upsert(row, { onConflict: 'user_id' })
    if (upErr) throw upErr

    // Aviso útil: sin refresh_token guardado el push no podrá renovarse.
    const { data: conn } = await admin
      .from('gmail_connections')
      .select('refresh_token')
      .eq('user_id', userId)
      .maybeSingle()
    const hasRefresh = !!conn?.refresh_token

    return json({ ok: true, expiration, hasRefreshToken: hasRefresh })
  } catch (error) {
    console.error('gmail-watch error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  })
}
