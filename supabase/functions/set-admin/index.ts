import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const supabase = createClient(supabaseUrl, supabaseServiceRoleKey)

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST',
        'Access-Control-Allow-Headers': 'authorization, content-type',
      },
    })
  }

  try {
    const authHeader = req.headers.get('authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'No authorization header' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const token = authHeader.replace('Bearer ', '')
    const { data: userData, error: authError } = await supabase.auth.getUser(token)
    if (authError || !userData.user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      })
    }

    // Solo un admin puede nombrar/quitar admins.
    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .select('is_admin')
      .eq('id', userData.user.id)
      .single()

    if (profileError || !profile?.is_admin) {
      return new Response(JSON.stringify({ error: 'Not admin' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const { userId, isAdmin } = await req.json()
    if (!userId || typeof isAdmin !== 'boolean') {
      return new Response(
        JSON.stringify({ error: 'Invalid request body: userId and isAdmin required' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      )
    }

    // Evitar que un admin se quite el admin a sí mismo y quede bloqueado.
    if (userId === userData.user.id && isAdmin === false) {
      return new Response(
        JSON.stringify({ error: 'No puedes quitarte admin a ti mismo' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      )
    }

    const { error: updateError } = await supabase
      .from('profiles')
      .update({ is_admin: isAdmin })
      .eq('id', userId)

    if (updateError) throw updateError

    return new Response(JSON.stringify({ success: true }), {
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    })
  } catch (error) {
    console.error('Error:', error)
    return new Response(JSON.stringify({ error: (error as Error).message }), {
      status: 500,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    })
  }
})
