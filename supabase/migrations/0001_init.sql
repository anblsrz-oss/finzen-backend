-- =====================================================================
-- FinZen — Migración inicial (Fase 1)
-- Tablas + RLS + trigger de perfil + seed de categorías + vistas de saldo
-- Pegar completo en Supabase -> SQL Editor -> Run.
-- Es re-ejecutable (usa IF NOT EXISTS / DROP ... IF EXISTS).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) PROFILES  (1:1 con auth.users)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  full_name   text,
  avatar_url  text,
  is_premium  boolean not null default false,
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Crear perfil automáticamente al registrarse un usuario nuevo.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 2) ACCOUNTS  (cuentas / bancos)
-- ---------------------------------------------------------------------
create table if not exists public.accounts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  bank_name       text,
  type            text not null default 'checking'
                    check (type in ('checking','savings','investment','cash')),
  currency        text not null default 'MXN',
  initial_balance numeric(14,2) not null default 0,
  has_yield       boolean not null default false,
  yield_rate      numeric(6,3),          -- % mensual (ej. 0.833 = 10% anual / 12)
  created_at      timestamptz not null default now()
);
create index if not exists accounts_user_id_idx on public.accounts(user_id);

-- ---------------------------------------------------------------------
-- 3) CARDS  (tarjetas de crédito y débito)
-- ---------------------------------------------------------------------
create table if not exists public.cards (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  name          text not null,
  brand         text,                    -- Visa, Mastercard, Amex...
  type          text not null default 'credit' check (type in ('credit','debit')),
  currency      text not null default 'MXN',
  account_id    uuid references public.accounts(id) on delete set null, -- débito: cuenta ligada
  credit_limit  numeric(14,2),           -- solo crédito
  cut_day       int check (cut_day between 1 and 31),      -- día de corte
  payment_day   int check (payment_day between 1 and 31),  -- día de pago
  created_at    timestamptz not null default now()
);
create index if not exists cards_user_id_idx on public.cards(user_id);

-- ---------------------------------------------------------------------
-- 4) CATEGORIES  (user_id null = categoría de sistema, visible para todos)
-- ---------------------------------------------------------------------
create table if not exists public.categories (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users(id) on delete cascade,
  name       text not null,
  kind       text not null check (kind in ('income','expense')),
  icon       text,
  color      text,
  is_system  boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists categories_user_id_idx on public.categories(user_id);

-- ---------------------------------------------------------------------
-- 5) TRANSACTIONS  (ingresos / egresos / transferencias)
--    - Egreso desde cuenta o débito: account_id = cuenta origen
--    - Egreso con crédito: card_id = tarjeta, account_id = NULL
--    - Transferencia: account_id = origen, to_account_id = destino
-- ---------------------------------------------------------------------
create table if not exists public.transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null check (kind in ('income','expense','transfer')),
  amount        numeric(14,2) not null check (amount >= 0),
  currency      text not null default 'MXN',
  concept       text,
  category_id   uuid references public.categories(id) on delete set null,
  account_id    uuid references public.accounts(id) on delete cascade,
  to_account_id uuid references public.accounts(id) on delete cascade,
  card_id       uuid references public.cards(id) on delete set null,
  tx_date       date not null default current_date,
  notes         text,
  created_at    timestamptz not null default now()
);
create index if not exists transactions_user_id_idx  on public.transactions(user_id);
create index if not exists transactions_account_idx  on public.transactions(account_id);
create index if not exists transactions_card_idx     on public.transactions(card_id);
create index if not exists transactions_tx_date_idx  on public.transactions(tx_date);

-- ---------------------------------------------------------------------
-- 6) INSTALLMENT_PLANS  (MSI / diferido — Premium)
-- ---------------------------------------------------------------------
create table if not exists public.installment_plans (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  card_id          uuid references public.cards(id) on delete set null,
  transaction_id   uuid references public.transactions(id) on delete cascade,
  description      text,
  total_amount     numeric(14,2) not null,
  currency         text not null default 'MXN',
  months           int not null check (months > 0),
  is_interest_free boolean not null default true,             -- true = MSI
  interest_amount  numeric(14,2) not null default 0,          -- cobro por diferir
  monthly_payment  numeric(14,2) not null,                    -- (total + interés)/meses
  start_date       date not null default current_date,
  created_at       timestamptz not null default now()
);
create index if not exists installment_plans_user_id_idx on public.installment_plans(user_id);

-- ---------------------------------------------------------------------
-- 7) YIELD_RECORDS  (verificación de rendimientos — Premium)
-- ---------------------------------------------------------------------
create table if not exists public.yield_records (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  account_id      uuid not null references public.accounts(id) on delete cascade,
  period_month    date not null,                 -- primer día del mes
  expected_growth numeric(14,2),                 -- calculado
  actual_growth   numeric(14,2),                 -- confirmado por el usuario
  verified        boolean not null default false,
  created_at      timestamptz not null default now(),
  unique (account_id, period_month)
);
create index if not exists yield_records_user_id_idx on public.yield_records(user_id);

-- ---------------------------------------------------------------------
-- 8) AI  (fase posterior — tablas listas, sin uso todavía)
-- ---------------------------------------------------------------------
create table if not exists public.ai_conversations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  title      text,
  created_at timestamptz not null default now()
);
create table if not exists public.ai_messages (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid references public.ai_conversations(id) on delete cascade,
  role            text not null check (role in ('user','assistant','system')),
  content         text not null,
  created_at      timestamptz not null default now()
);
create index if not exists ai_conversations_user_id_idx on public.ai_conversations(user_id);
create index if not exists ai_messages_user_id_idx       on public.ai_messages(user_id);

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles          enable row level security;
alter table public.accounts          enable row level security;
alter table public.cards             enable row level security;
alter table public.categories        enable row level security;
alter table public.transactions      enable row level security;
alter table public.installment_plans enable row level security;
alter table public.yield_records     enable row level security;
alter table public.ai_conversations  enable row level security;
alter table public.ai_messages       enable row level security;

-- PROFILES: cada quien ve solo su perfil. NO se permite UPDATE desde el cliente
-- (para que nadie se auto-asigne is_premium / is_admin). Esos cambios se hacen
-- vía la Edge Function set-premium (service_role) en la Fase 6.
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select using (id = auth.uid());

-- Helper genérico: política dueño para tablas con columna user_id.
-- (Se define por tabla explícitamente para claridad.)

-- ACCOUNTS
drop policy if exists accounts_all_own on public.accounts;
create policy accounts_all_own on public.accounts
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- CARDS
drop policy if exists cards_all_own on public.cards;
create policy cards_all_own on public.cards
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- CATEGORIES: ver propias + de sistema; escribir solo las propias.
drop policy if exists categories_select on public.categories;
create policy categories_select on public.categories
  for select using (user_id = auth.uid() or user_id is null);
drop policy if exists categories_insert_own on public.categories;
create policy categories_insert_own on public.categories
  for insert with check (user_id = auth.uid());
drop policy if exists categories_update_own on public.categories;
create policy categories_update_own on public.categories
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists categories_delete_own on public.categories;
create policy categories_delete_own on public.categories
  for delete using (user_id = auth.uid());

-- TRANSACTIONS
drop policy if exists transactions_all_own on public.transactions;
create policy transactions_all_own on public.transactions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- INSTALLMENT_PLANS
drop policy if exists installment_plans_all_own on public.installment_plans;
create policy installment_plans_all_own on public.installment_plans
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- YIELD_RECORDS
drop policy if exists yield_records_all_own on public.yield_records;
create policy yield_records_all_own on public.yield_records
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- AI
drop policy if exists ai_conversations_all_own on public.ai_conversations;
create policy ai_conversations_all_own on public.ai_conversations
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists ai_messages_all_own on public.ai_messages;
create policy ai_messages_all_own on public.ai_messages
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- =====================================================================
-- VISTAS CALCULADAS  (security_invoker => respetan la RLS del que consulta)
-- =====================================================================

-- Saldo actual por cuenta.
drop view if exists public.account_balances;
create view public.account_balances
  with (security_invoker = true) as
select
  a.id            as account_id,
  a.user_id,
  a.name,
  a.currency,
  a.initial_balance
    + coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.kind = 'income'), 0)
    - coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.kind = 'expense'), 0)
    - coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.kind = 'transfer'), 0)
    + coalesce((select sum(t.amount) from public.transactions t
        where t.to_account_id = a.id and t.kind = 'transfer'), 0)
  as current_balance
from public.accounts a;

-- Uso y disponible por tarjeta de crédito.
-- 'used' = suma de egresos cargados a la tarjeta. (El pago del estado de cuenta
-- se modelará en fases posteriores; por ahora es la suma de consumos.)
drop view if exists public.card_usage;
create view public.card_usage
  with (security_invoker = true) as
select
  c.id           as card_id,
  c.user_id,
  c.name,
  c.currency,
  c.credit_limit,
  coalesce((select sum(t.amount) from public.transactions t
      where t.card_id = c.id and t.kind = 'expense'), 0) as used,
  coalesce(c.credit_limit, 0)
    - coalesce((select sum(t.amount) from public.transactions t
        where t.card_id = c.id and t.kind = 'expense'), 0) as available
from public.cards c
where c.type = 'credit';

grant select on public.account_balances to authenticated;
grant select on public.card_usage       to authenticated;

-- =====================================================================
-- SEED — categorías de sistema (user_id null, visibles para todos)
-- =====================================================================
insert into public.categories (name, kind, icon, color, is_system)
select * from (values
  ('Sueldo/Salario',   'income',  '💼', '#16a34a', true),
  ('Rendimientos',     'income',  '📈', '#0d9488', true),
  ('Otros ingresos',   'income',  '➕', '#65a30d', true),
  ('Supermercado',     'expense', '🛒', '#f59e0b', true),
  ('Suscripciones',    'expense', '📺', '#8b5cf6', true),
  ('Servicios',        'expense', '🔌', '#0ea5e9', true),
  ('Transporte',       'expense', '🚗', '#ef4444', true),
  ('Restaurantes',     'expense', '🍽️', '#f97316', true),
  ('Salud',            'expense', '🏥', '#ec4899', true),
  ('Tarjeta de crédito','expense','💳', '#6366f1', true),
  ('Sin categoría',    'expense', '❓', '#94a3b8', true)
) as v(name, kind, icon, color, is_system)
where not exists (
  select 1 from public.categories c where c.is_system = true and c.name = v.name
);
