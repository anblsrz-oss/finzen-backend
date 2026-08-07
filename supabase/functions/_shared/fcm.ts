// Push notifications vía Firebase Cloud Messaging, API HTTP v1.
//
// A diferencia de Gmail (gmail.ts), aquí NO hay un usuario detrás con un
// refresh_token: quien envía es la APP MISMA, autenticada como una cuenta de
// servicio de Google Cloud. El flujo es "JWT Bearer" (RFC 7523): se firma un
// JWT con la llave privada de la cuenta de servicio y se cambia por un access
// token de 1h en el endpoint estándar de OAuth2 de Google — no hay nada
// específico de Firebase en este intercambio, es el mismo mecanismo que usa
// cualquier API de Google Cloud detrás de una cuenta de servicio.
//
// Secret: FCM_SERVICE_ACCOUNT = el JSON de la cuenta de servicio (Firebase
// Console → Configuración del proyecto → Cuentas de servicio → Generar nueva
// clave privada), codificado en base64 para que quepa como variable de
// entorno de una sola línea sin pelear con los saltos de línea de la PEM.

interface ServiceAccount {
  project_id: string
  client_email: string
  private_key: string
  token_uri?: string
}

function base64UrlFromBytes(bytes: Uint8Array): string {
  let bin = ''
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function base64UrlFromString(s: string): string {
  return base64UrlFromBytes(new TextEncoder().encode(s))
}

// La PEM viene con cabeceras y saltos de línea; Web Crypto quiere los bytes
// DER crudos.
function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '')
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes.buffer
}

export function parseServiceAccount(base64Json: string): ServiceAccount {
  let text: string
  try {
    text = atob(base64Json)
  } catch {
    throw new Error('FCM_SERVICE_ACCOUNT no es base64 válido')
  }
  const parsed = JSON.parse(text)
  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    throw new Error('FCM_SERVICE_ACCOUNT no trae project_id/client_email/private_key')
  }
  return parsed as ServiceAccount
}

// Cambia la cuenta de servicio por un access token de Google Cloud con el
// scope de FCM. Válido ~1h; para un cron que corre una vez al día no hace
// falta cachear entre invocaciones, un token por ejecución es suficiente.
export async function getFcmAccessToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = { alg: 'RS256', typ: 'JWT' }
  const claims = {
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: account.token_uri ?? 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }
  const unsigned = `${base64UrlFromString(JSON.stringify(header))}.${base64UrlFromString(JSON.stringify(claims))}`

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(unsigned),
  )
  const jwt = `${unsigned}.${base64UrlFromBytes(new Uint8Array(signature))}`

  const res = await fetch(account.token_uri ?? 'https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  })
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(`Intercambio de token FCM falló: ${res.status} ${detail.slice(0, 300)}`)
  }
  const json = await res.json()
  return json.access_token as string
}

export interface FcmSendResult {
  ok: boolean
  /** true si Google dice que el token ya no es válido: hay que borrarlo. */
  invalidToken: boolean
  error?: string
}

// Un envío = una notificación a UN token de dispositivo. Quien llama itera
// sobre los tokens (un usuario puede tener varios dispositivos).
export async function sendFcmPush(
  accessToken: string,
  projectId: string,
  deviceToken: string,
  notification: { title: string; body: string },
  data?: Record<string, string>,
): Promise<FcmSendResult> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token: deviceToken,
          notification,
          data: data ?? {},
          android: { priority: 'high' },
        },
      }),
    },
  )
  if (res.ok) return { ok: true, invalidToken: false }

  const detail = await res.text().catch(() => '')
  // UNREGISTERED / INVALID_ARGUMENT sobre el campo token = el registro venció
  // (desinstaló la app, token rotado). Limpiarlo evita seguir intentando para
  // siempre contra un destino muerto. Frases tomadas de las respuestas reales
  // de FCM HTTP v1 para tokens inválidos/desregistrados.
  const invalidToken =
    /UNREGISTERED|NOT_FOUND|INVALID_ARGUMENT|requested entity was not found|not a valid fcm registration token/i.test(
      detail,
    )
  return { ok: false, invalidToken, error: detail.slice(0, 300) }
}
