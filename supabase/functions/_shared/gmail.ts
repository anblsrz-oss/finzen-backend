// Helpers de Gmail API compartidos por gmail-push y gmail-watch-renew.
// El refresh del access token usa el client_id/secret de la app de Google
// (los mismos que Supabase Auth usa para el proveedor Google).

const GOOGLE_CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID')!
const GOOGLE_CLIENT_SECRET = Deno.env.get('GOOGLE_CLIENT_SECRET')!

// Cambia un refresh_token de larga vida por un access_token de ~1h.
export async function refreshAccessToken(refreshToken: string): Promise<string> {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
    }),
  })
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(`refresh token falló: ${res.status} ${detail.slice(0, 300)}`)
  }
  const j = await res.json()
  return j.access_token as string
}

const authGet = (url: string, accessToken: string) =>
  fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } })

// Activa/renueva el push. Devuelve historyId + expiration (epoch ms como string).
export async function gmailWatch(
  accessToken: string,
  topicName: string,
): Promise<{ historyId: string; expiration: string }> {
  const res = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/watch', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ topicName, labelIds: ['INBOX'] }),
  })
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(`users.watch falló: ${res.status} ${detail.slice(0, 300)}`)
  }
  return await res.json()
}

export async function gmailStop(accessToken: string): Promise<void> {
  await fetch('https://gmail.googleapis.com/gmail/v1/users/me/stop', {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}` },
  }).catch(() => {})
}

// IDs de mensajes AÑADIDOS desde startHistoryId (dedup por id).
export async function listAddedMessageIds(
  accessToken: string,
  startHistoryId: string,
): Promise<string[]> {
  const ids = new Set<string>()
  let pageToken: string | undefined
  do {
    const url =
      `https://gmail.googleapis.com/gmail/v1/users/me/history` +
      `?startHistoryId=${encodeURIComponent(startHistoryId)}` +
      `&historyTypes=messageAdded&maxResults=100` +
      (pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : '')
    const res = await authGet(url, accessToken)
    if (!res.ok) break
    const j = await res.json()
    for (const h of j.history ?? []) {
      for (const m of h.messagesAdded ?? []) {
        if (m.message?.id) ids.add(m.message.id)
      }
    }
    pageToken = j.nextPageToken
  } while (pageToken)
  return [...ids]
}

export async function getMessage(accessToken: string, id: string): Promise<any | null> {
  const res = await authGet(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}?format=full`,
    accessToken,
  )
  if (!res.ok) return null
  return await res.json()
}

export async function getAttachmentData(
  accessToken: string,
  msgId: string,
  attId: string,
): Promise<string | null> {
  const res = await authGet(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages/${msgId}/attachments/${attId}`,
    accessToken,
  )
  if (!res.ok) return null
  const j = await res.json()
  return j.data ?? null
}
