# Ahorbit Backend

Supabase backend para Ahorbit (antes FinZen) — Control de finanzas personales.

Este repositorio es la **fuente de verdad del backend**: migraciones SQL y Edge Functions.
El frontend vive en un repo aparte (`finzen-frontend`) para mantener la separación de responsabilidades.

## Contenido

### Migraciones (`supabase/migrations/`)

- `0001_init.sql` — Schema completo: tablas, vistas, RLS, triggers y seed de categorías
- `0002_ingestion.sql` — Ingesta de movimientos
- `0003_transaction_deletions.sql` — Borrado de transacciones
- `0004_family.sql` — Familias / cuentas compartidas
- `0005_receipts.sql` — Recibos
- `0006_billing.sql` — Facturación (Stripe)
- `0007_family_security_hardening.sql` / `0008_family_security_hardening_fix.sql` — Endurecimiento RLS de familias
- `0009_multicurrency.sql` — Multimoneda
- `0012_mvp3_management.sql` — Gestión MVP3
- `0013_card_visual.sql` — Personalización visual de tarjetas
- `0014_app_config.sql` — Configuración de app
- `0015_card_cashback.sql` — Cashback de tarjetas
- `0016_app_config_theme.sql` — Tema (admin)
- `0017_system_categories_icons.sql` — Iconos de categorías del sistema
- `0018_credit_lines.sql` — Líneas de crédito compartidas
- `0019_card_format.sql` — Formato virtual / marca de tarjeta
- `0020_credit_line_periods.sql` — Periodos reales de líneas de crédito
- `0021_balance_adjustment_category.sql` — Categoría de ajuste de saldo
- `0022_account_yields.sql` — Rendimientos anuales de cuentas
- `0023_credit_usage_net.sql` — Uso neto de crédito
- `0024_transaction_filter_indexes.sql` — Índices para filtros de transacciones
- `0025_tx_kind_card_payment.sql` — Tipo de movimiento "pago de tarjeta"
- `0026_card_payments.sql` — Pagos de tarjeta y vistas de saldo/uso recalculadas
- `0027_installment_tracking.sql` / `0028_backfill_installment_ledger.sql` — Ledger de MSI mes a mes
- `0029_voucher_card_and_account_type.sql` — Tarjetas y cuentas de vales
- `0030_card_bank_name.sql` — Banco de la tarjeta
- `0031_profiles_first_last_name.sql` — Nombre y apellido en el perfil
- `0032_sms_device_tokens.sql` — Tokens de dispositivo para la captura de SMS
- `0033_gmail_connections.sql` — Conexiones de Gmail (push en tiempo real)
- `0034_cleanup_email_false_positives.sql` — Limpieza de falsos positivos del correo
- `0035_fix_transfer_shape_external.sql` — Forma de las transferencias externas
- `0036_app_config_period_filters.sql` — Flags premium del selector de periodo
- `0037_budgets.sql` — Presupuestos: tabla, periodos y `budget_status_at()`
- `0038_budget_alerts.sql` — Avisos de presupuesto (dedupe) y `record_budget_alerts()`
- `0039_budget_alerts_cron.sql` — Aviso por correo: opt-in y `record_budget_alerts_all()`

### Edge Functions (`supabase/functions/`)

- `list-users/` — Listar usuarios (admin only)
- `set-premium/` — Marcar usuarios como premium (admin only)
- `set-admin/` — Marcar usuarios como admin (admin only)
- `create-checkout-session/` — Crear sesión de checkout de Stripe
- `create-portal-session/` — Crear sesión del portal de facturación de Stripe
- `stripe-webhook/` — Webhook de Stripe
- `fx-rate/` — Tipo de cambio
- `invite-family-email/` — Invitación de familia por correo
- `send-feedback/` — Envío de feedback
- `sync-aggregator/` — Sincronización con agregador
- `sync-email/` — Sincronización por correo (pull manual)
- `gmail-push/` — Webhook de Gmail Pub/Sub (captura en tiempo real). `--no-verify-jwt`
- `gmail-watch/` — Activa el `users.watch` de Gmail
- `gmail-watch-renew/` — Renueva el watch antes de que expire. Lo llama un cron. `--no-verify-jwt`
- `ingest-sms/` — Ingesta de SMS bancarios desde el receptor nativo Android. `--no-verify-jwt`
- `budget-alerts-email/` — Aviso diario de presupuestos por correo. Lo llama un cron. `--no-verify-jwt`

### Crons (`pg_cron`, se agendan a mano en el SQL Editor)

| Job | Horario (UTC) | Qué llama |
|---|---|---|
| `gmail-watch-renew-daily` | `0 6 * * *` | `gmail-watch-renew` |
| `budget-alerts-daily` | `0 14 * * *` (08:00 CST) | `budget-alerts-email` |

Ambos se autorizan con el header `x-cron-secret` (secret `CRON_SECRET`).
Ver el bloque comentado al final de `0039_budget_alerts_cron.sql`.

## Deployment

```bash
# Migraciones: pegar el SQL en Supabase -> SQL Editor -> Run
# (los archivos son re-ejecutables con IF NOT EXISTS / DROP ... IF EXISTS)

# Edge Functions
supabase functions deploy <nombre-de-la-funcion>
```

## Tablas principales

- `profiles` — Usuarios (id, email, is_premium, is_admin)
- `accounts` — Cuentas/bancos (multimoneda)
- `cards` — Tarjetas de crédito/débito
- `transactions` — Ingresos, egresos, transferencias
- `categories` — Categorías de gasto
- `installment_plans` — MSI/diferido (premium)
- `yield_records` — Rendimientos verificados (premium)

## Vistas calculadas

- `account_balances` — Saldo actual por cuenta
- `card_usage` — Uso y disponible de tarjetas de crédito

## Row Level Security

Todas las tablas tienen políticas RLS que aseguran que cada usuario solo ve sus propios datos.
