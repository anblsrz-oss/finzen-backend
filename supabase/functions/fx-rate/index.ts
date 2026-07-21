// Devuelve el tipo de cambio base->quote y lo cachea en la tabla fx_rates.
// Fuente: frankfurter.app (gratis, sin API key, datos del BCE). Soporta MXN,
// USD, EUR, GBP, CAD, etc. Si el par no está soportado, responde error y el
// cliente puede pedir la tasa manual.
//
// Llamada autenticada (functions.invoke adjunta el JWT del usuario).
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
)

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
    const body = await req.json().catch(() => ({}))
    const base = String(body.base ?? '').toUpperCase()
    const quote = String(body.quote ?? '').toUpperCase()
    // Fecha en formato YYYY-MM-DD; por defecto hoy (UTC).
    const date =
      typeof body.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(body.date)
        ? body.date
        : new Date().toISOString().slice(0, 10)

    if (!base || !quote) return json({ error: 'base y quote son requeridos' }, 400)
    if (base === quote) return json({ rate: 1, date, base, quote, cached: false })

    // 1) Caché.
    const { data: cached } = await supabase
      .from('fx_rates')
      .select('rate')
      .eq('rate_date', date)
      .eq('base', base)
      .eq('quote', quote)
      .maybeSingle()
    if (cached?.rate) {
      return json({ rate: Number(cached.rate), date, base, quote, cached: true })
    }

    // 2) API externa.
    const url = `https://api.frankfurter.app/${date}?from=${base}&to=${quote}`
    const res = await fetch(url)
    if (!res.ok) return json({ error: 'No se pudo obtener el tipo de cambio' }, 502)
    const data = await res.json()
    const rate = data?.rates?.[quote]
    if (typeof rate !== 'number') {
      return json({ error: `Par ${base}/${quote} no soportado` }, 422)
    }
    // frankfurter puede devolver la fecha hábil más cercana; úsala para cachear.
    const effectiveDate = typeof data.date === 'string' ? data.date : date

    // 3) Guardar en caché (best effort).
    await supabase
      .from('fx_rates')
      .upsert(
        { rate_date: effectiveDate, base, quote, rate },
        { onConflict: 'rate_date,base,quote' },
      )

    return json({ rate, date: effectiveDate, base, quote, cached: false })
  } catch (error) {
    console.error('fx-rate error:', error)
    return json({ error: (error as Error).message }, 500)
  }
})
