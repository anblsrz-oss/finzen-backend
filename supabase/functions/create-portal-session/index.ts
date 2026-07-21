// Crea una sesión del portal de facturación de Stripe para que el usuario
// gestione o cancele su suscripción Premium.
//
// Secrets requeridos: STRIPE_SECRET_KEY
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import Stripe from 'https://esm.sh/stripe@14?target=deno'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
)
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, {
  apiVersion: '2023-10-16',
  httpClient: Stripe.createFetchHttpClient(),
})

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST',
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
    const authHeader = req.headers.get('authorization')
    if (!authHeader) return json({ error: 'No authorization header' }, 401)

    const token = authHeader.replace('Bearer ', '')
    const { data: userData, error: authError } = await supabase.auth.getUser(token)
    if (authError || !userData.user) return json({ error: 'Unauthorized' }, 401)

    const { returnUrl } = await req.json().catch(() => ({ returnUrl: undefined }))
    const baseUrl = returnUrl || `${new URL(req.url).origin}`

    const { data: profile } = await supabase
      .from('profiles')
      .select('stripe_customer_id')
      .eq('id', userData.user.id)
      .single()

    if (!profile?.stripe_customer_id) {
      return json({ error: 'No Stripe customer' }, 400)
    }

    const session = await stripe.billingPortal.sessions.create({
      customer: profile.stripe_customer_id,
      return_url: `${baseUrl}/configuracion`,
    })

    return json({ url: session.url })
  } catch (error) {
    console.error('create-portal-session error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})
