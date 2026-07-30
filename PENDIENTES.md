# Pendientes — Arreglo de sincronización de correo

## Trabajo completado (commit `41c1a46`)

✅ **Código:** Arreglo central del filtro de remitente obligatorio en parseEmail.ts  
✅ **Limpieza HTML:** extractBody ahora prefiere text/plain y limpia markup  
✅ **Regex de monto:** Preferencia por moneda pegada sobre números genéricos  
✅ **Barreras:** gmail-push aborta sin reglas; sync-email filtra por user_id  
✅ **Tests:** parseEmail.test.ts — 12 casos, todos en verde  
✅ **Migración:** 0034_cleanup_email_false_positives.sql lista para ejecutar  

---

## Falta hacer

### 1. **Desplegar Edge Functions** (bloqueador)

Las funciones `sync-email` y `gmail-push` están en el repo pero sin desplegar a Supabase.

**Opción A: CLI (si logra conectar)**
```powershell
npx supabase@latest functions deploy sync-email --project-ref vujlizgyharlhcmfgkti
npx supabase@latest functions deploy gmail-push --project-ref vujlizgyharlhcmfgkti --no-verify-jwt
```

**Opción B: UI de Supabase (recomendado)**
- Ve a **Functions** en la consola
- Edita `sync-email` y `gmail-push` con el contenido de:
  - `supabase/functions/sync-email/index.ts`
  - `supabase/functions/gmail-push/index.ts`
- Deploy desde la web

---

### 2. **Ejecutar la migración de limpieza** (bloqueador)

Borra las 18 transacciones pendientes falsas generadas por el bug.

**Antes de ejecutar, verifica cuántas van a borrarse:**
```sql
select count(*) as "Transacciones a limpiar", min(tx_date) as "Desde", max(tx_date) as "Hasta"
from public.transactions
where source = 'email' and pending = true;
```
Debe salir `18` o el número que sea. Si algo está distinto, **no ejecutes la migración**.

**Ejecutar:**
- Ve a **SQL Editor** en Supabase
- Pega el contenido de `supabase/migrations/0034_cleanup_email_false_positives.sql`
- Run

---

### 3. **Pruebas end-to-end** (post-deploy)

Una vez deployed:

#### Push en tiempo real (gmail-push)
- Activa "Captura automática en tiempo real" en la app (Sincronizar correo → Activar tiempo real)
- Envíate un correo cualquiera (no bancario)
- Verifica logs: `supabase functions logs gmail-push`
- Confirma que **no** aparece como transacción

#### Pull manual (sync-email)
- Pulsa "Sincronizar ahora" en la app
- Confirma que reporta `inserted: 0` o solo las transacciones de remitentes reales
- No debería haber basura tipo `-$0.25`, `-$0.05`, etc.

#### CFDI
- Envíate un correo con un XML adjunto de factura de cualquier remitente
- Confirma que se registra (la ruta CFDI no exige remitente configurado)

---

## Notas

- El código está en `main`, pusheado a GitHub
- Los tests pasan 12/12 localmente
- Sin los deploys en Supabase, los cambios no aplican en producción
- La migración es idempotente; se puede ejecutar varias veces sin problemas
