# FinZen Backend

Supabase backend para FinZen - Control de finanzas personales.

## Contenido

- `migrations/0001_init.sql` — Schema completo con tablas, vistas, RLS, triggers y seed de categorías
- `functions/list-users/` — Edge Function para listar usuarios (admin only)
- `functions/set-premium/` — Edge Function para marcar usuarios como premium (admin only)

## Deployment

```bash
# Desplegar Edge Functions
supabase functions deploy list-users
supabase functions deploy set-premium
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
