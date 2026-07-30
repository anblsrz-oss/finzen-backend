import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { refreshAccessToken, gmailWatch } from '../_shared/gmail.ts'

// Renueva el users.watch de Gmail (expira máx. 7 días) para todas las conexiones
// que estén por vencer. Sin esto, el push deja de llegar en silencio.
// La llama un cron (pg_cron + pg_net) a diario. Se protege con un secret.
//
// Desplegar SIN verificación de JWT (lo llama el cron):
//   supabase functions deploy gmail-watch-renew --no-verify-jwt
// Secrets: CRON_SECRET, GMAIL_PUBSUB_TOPIC, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const TOPIC = Deno.env.get('GMAIL_PUBSUB_TOPIC')!
const CRON_SECRET = Deno.env.get('CRON_SECRET')!

serve(async (req) => {
  try {
    // Autorización del cron: header x-cron-secret.
    if (req.headers.get('x-cron-secret') !== CRON_SECRET) {
      return json({ error: 'forbidden' }, 403)
    }

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)

    // Conexiones que vencen en las próximas 48h (o ya vencidas / sin fecha).
    const soon = new Date(Date.now() + 48 * 3600_000).toISOString()
    const { data: conns } = await admin
      .from('gmail_connections')
      .select('user_id, refresh_token, watch_expiration')
      .not('refresh_token', 'is', null)
      .or(`watch_expiration.lte.${soon},watch_expiration.is.null`)

    let renewed = 0
    let failed = 0
    for (const c of conns ?? []) {
      try {
        const accessToken = await refreshAccessToken(c.refresh_token as string)
        const watch = await gmailWatch(accessToken, TOPIC)
        const expiration = watch.expiration
          ? new Date(parseInt(watch.expiration, 10)).toISOString()
          : null
        await admin
          .from('gmail_connections')
          .update({
            history_id: watch.historyId,
            watch_expiration: expiration,
            updated_at: new Date().toISOString(),
          })
          .eq('user_id', c.user_id as string)
        renewed++
      } catch (e) {
        console.error('renovación falló para', c.user_id, (e as Error).message)
        failed++
      }
    }

    return json({ renewed, failed, checked: conns?.length ?? 0 })
  } catch (error) {
    console.error('gmail-watch-renew error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}
