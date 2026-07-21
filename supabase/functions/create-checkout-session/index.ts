// Crea una sesión de Stripe Checkout para la suscripción Premium de Ahorbit.
// El usuario autenticado (JWT) inicia el pago; al completarse, el webhook
// stripe-webhook marca is_premium = true.
//
// Secrets requeridos (supabase functions secrets set ...):
//   STRIPE_SECRET_KEY, STRIPE_PRICE_ID
// Env ya presentes en Functions: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
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

    const user = userData.user
    const { returnUrl } = await req.json().catch(() => ({ returnUrl: undefined }))
    const baseUrl = returnUrl || `${new URL(req.url).origin}`

    // Reutiliza el customer de Stripe si ya existe.
    const { data: profile } = await supabase
      .from('profiles')
      .select('stripe_customer_id, email')
      .eq('id', user.id)
      .single()

    let customerId = profile?.stripe_customer_id as string | null
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: profile?.email ?? user.email ?? undefined,
        metadata: { supabase_user_id: user.id },
      })
      customerId = customer.id
      await supabase
        .from('profiles')
        .update({ stripe_customer_id: customerId })
        .eq('id', user.id)
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      customer: customerId,
      line_items: [{ price: Deno.env.get('STRIPE_PRICE_ID')!, quantity: 1 }],
      success_url: `${baseUrl}/configuracion?checkout=success`,
      cancel_url: `${baseUrl}/configuracion?checkout=cancel`,
      metadata: { supabase_user_id: user.id },
    })

    return json({ url: session.url })
  } catch (error) {
    console.error('create-checkout-session error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})
