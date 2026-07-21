import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

// STUB — Conexión con agregador de Open Finance (Belvo/Finerio) para sincronizar
// movimientos automáticamente. Función Premium futura: no se contrata el
// agregador todavía (~$1,000 USD/mes). Cuando se active:
//   1) Crear widget/token del agregador y guardar el link en `bank_connections`.
//   2) Consumir sus webhooks/endpoints de transactions.
//   3) Insertar en `transactions` con source='aggregator', dedupe por external_id.
// Por ahora responde "no implementado" para dejar el andamiaje listo.
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
  return new Response(
    JSON.stringify({
      status: 'not_implemented',
      message: 'Conexión automática con banco disponible en una versión Premium futura.',
    }),
    {
      status: 501,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    },
  )
})
