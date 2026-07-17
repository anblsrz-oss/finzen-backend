# Configuración de Supabase — FinZen (Fase 1)

Proyecto Supabase: `vujlizgyharlhcmfgkti`
URL: `https://vujlizgyharlhcmfgkti.supabase.co`

## 1. Aplicar la migración de base de datos

1. Abre Supabase → **SQL Editor** → **New query**.
2. Copia y pega TODO el contenido de [`migrations/0001_init.sql`](migrations/0001_init.sql).
3. Presiona **Run**. Debe terminar sin errores.
4. Verifica en **Table Editor** que existan: `profiles`, `accounts`, `cards`,
   `categories`, `transactions`, `installment_plans`, `yield_records`,
   `ai_conversations`, `ai_messages`. En `categories` deben aparecer las
   categorías de sistema (Sueldo/Salario, Supermercado, etc.).

> Alternativa con CLI: `supabase link --project-ref vujlizgyharlhcmfgkti` y luego
> `supabase db push`.

## 2. Configurar Google OAuth

### 2.1 En Google Cloud Console (APIs & Services → Credentials → Create OAuth client ID)
- Tipo de aplicación: **Web application**
- **Authorized JavaScript origins:**
  - `http://localhost:5173`
  - (más adelante) la URL de producción, p. ej. `https://finzen.vercel.app`
- **Authorized redirect URIs:**
  - `https://vujlizgyharlhcmfgkti.supabase.co/auth/v1/callback`
- Al crear, Google te da **Client ID** y **Client Secret**.

Client ID actual:
`413281646856-2nab9o1fii4g0j98fb29i1vts1on8i4h.apps.googleusercontent.com`

### 2.2 En Supabase (Authentication → Providers → Google)
- Activa **Google**.
- Pega el **Client ID** y el **Client Secret**.
- Guarda.

### 2.3 En Supabase (Authentication → URL Configuration)
- **Site URL:** `http://localhost:5173` (en producción, cambiar a la URL real).
- **Redirect URLs:** agrega `http://localhost:5173` y la URL de producción.

## 3. Variables de entorno del frontend
En `.env.local` (ya creado, git-ignored):

```
VITE_SUPABASE_URL=https://vujlizgyharlhcmfgkti.supabase.co
VITE_SUPABASE_ANON_KEY=<tu anon/publishable key>
```

## 4. Probar
1. `npm run dev`
2. Abre `http://localhost:5173`, te manda a `/login`.
3. "Continuar con Google" → inicia sesión.
4. En Supabase → Table Editor → `profiles` debe aparecer tu usuario.
5. Vuelve a la app: deberías ver el layout con tu nombre en la barra superior.

## 5. Marcar tu usuario como admin + premium (para pruebas)
Después de tu primer login, corre en el SQL Editor:

```sql
update public.profiles
set is_admin = true, is_premium = true
where email = 'alsuarez@thepalacecompany.com';
```

## Notas de seguridad
- El frontend usa solo la **anon/publishable key** (pública). Nunca pongas la
  `service_role` key en el cliente.
- La tabla `profiles` **no** permite UPDATE desde el cliente (para que nadie se
  auto-active premium/admin). Esos cambios se hacen por SQL o, en la Fase 6, con la
  Edge Function `set-premium` (service_role).
- Rota la contraseña de la base de datos que se compartió en el chat.
