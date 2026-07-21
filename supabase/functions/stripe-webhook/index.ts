// Webhook de Stripe: activa/desactiva Premium según el estado de la suscripción.
// Es Stripe quien llama, NO un usuario => desplegar SIN verificación de JWT:
//   supabase functions deploy stripe-webhook --no-verify-jwt
//
// Configurar en el dashboard de Stripe un webhook a:
//   https://<PROJECT_REF>.supabase.co/functions/v1/stripe-webhook
// con los eventos: checkout.session.completed, customer.subscription.updated,
// customer.subscription.deleted.
//
// Secrets requeridos: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
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
const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')!

// Marca premium para el customer dado, con vigencia opcional.
async function setPremiumByCustomer(
  customerId: string,
  isPremium: boolean,
  premiumUntil: string | null,
) {
  const { data: profile } = await supabase
    .from('profiles')
    .select('id')
    .eq('stripe_customer_id', customerId)
    .maybeSingle()
  if (!profile) return
  await supabase
    .from('profiles')
    .update({ is_premium: isPremium, premium_until: premiumUntil })
    .eq('id', profile.id)
}

serve(async (req) => {
  const signature = req.headers.get('stripe-signature')
  if (!signature) return new Response('No signature', { status: 400 })

  const body = await req.text()
  let event: Stripe.Event
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      webhookSecret,
    )
  } catch (err) {
    console.error('Webhook signature verification failed:', err)
    return new Response('Invalid signature', { status: 400 })
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object as Stripe.Checkout.Session
        if (session.customer) {
          await setPremiumByCustomer(String(session.customer), true, null)
        }
        break
      }
      case 'customer.subscription.updated': {
        const sub = event.data.object as Stripe.Subscription
        const active = sub.status === 'active' || sub.status === 'trialing'
        const until = sub.current_period_end
          ? new Date(sub.current_period_end * 1000).toISOString()
          : null
        await setPremiumByCustomer(String(sub.customer), active, until)
        break
      }
      case 'customer.subscription.deleted': {
        const sub = event.data.object as Stripe.Subscription
        await setPremiumByCustomer(String(sub.customer), false, null)
        break
      }
    }
    return new Response(JSON.stringify({ received: true }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (error) {
    console.error('stripe-webhook error:', error)
    return new Response(JSON.stringify({ error: (error as Error).message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
