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
- `sync-email/` — Sincronización por correo

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
