-- =====================================================================
-- Ahorbit — Migración de ingesta de movimientos (Fase 8)
-- Extiende `transactions` con origen/dedupe/pendiente + tablas de import,
-- staging, reglas de parseo y conexiones de agregador (andamiaje).
-- Pegar completo en Supabase -> SQL Editor -> Run.
-- Es re-ejecutable (IF NOT EXISTS / DROP ... IF EXISTS / bloques DO).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) TRANSACTIONS: origen, id externo (dedupe), pendiente y referencia
-- ---------------------------------------------------------------------
alter table public.transactions
  add column if not exists source      text not null default 'manual',
  add column if not exists external_id text,
  add column if not exists pending     boolean not null default false,
  add column if not exists raw_ref      uuid;

-- Check del origen (idempotente).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'transactions_source_chk'
  ) then
    alter table public.transactions
      add constraint transactions_source_chk
      check (source in ('manual','import','email','sms','aggregator'));
  end if;
end $$;

-- Dedupe: no repetir un mismo movimiento externo por usuario.
create unique index if not exists transactions_ext_uidx
  on public.transactions(user_id, external_id)
  where external_id is not null;

create index if not exists transactions_pending_idx
  on public.transactions(user_id, pending) where pending = true;

-- ---------------------------------------------------------------------
-- 2) STATEMENT_IMPORTS: un lote por archivo/canal importado
-- ---------------------------------------------------------------------
create table if not exists public.statement_imports (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  account_id     uuid references public.accounts(id) on delete set null, -- cuenta destino
  bank_name      text,
  channel        text not null default 'csv'
                   check (channel in ('csv','pdf','email','sms')),
  file_name      text,
  status         text not null default 'staged'
                   check (status in ('parsing','staged','confirmed','failed')),
  total_rows     int not null default 0,
  imported_rows  int not null default 0,
  created_at     timestamptz not null default now()
);
create index if not exists statement_imports_user_id_idx
  on public.statement_imports(user_id);

-- ---------------------------------------------------------------------
-- 3) IMPORT_STAGING: filas parseadas a la espera de confirmación
--    Al confirmar se promueven a public.transactions.
-- ---------------------------------------------------------------------
create table if not exists public.import_staging (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  import_id     uuid references public.statement_imports(id) on delete cascade,
  tx_date       date,
  amount        numeric(14,2),
  kind          text check (kind in ('income','expense','transfer')),
  concept       text,
  category_id   uuid references public.categories(id) on delete set null,
  account_id    uuid references public.accounts(id) on delete set null,
  card_id       uuid references public.cards(id) on delete set null,
  external_id   text,                       -- hash del origen (dedupe)
  raw_text      text,                       -- línea/correo/SMS original
  status        text not null default 'pending'
                  check (status in ('pending','confirmed','discarded','duplicate')),
  created_at    timestamptz not null default now()
);
create index if not exists import_staging_user_id_idx
  on public.import_staging(user_id);
create index if not exists import_staging_import_idx
  on public.import_staging(import_id);

-- ---------------------------------------------------------------------
-- 4) PARSING_RULES: mapeo de columnas CSV / regex de correo o SMS por banco
-- ---------------------------------------------------------------------
create table if not exists public.parsing_rules (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  bank_name  text not null,
  channel    text not null default 'csv'
               check (channel in ('csv','pdf','email','sms')),
  config     jsonb not null default '{}'::jsonb,   -- {columns:{date,amount,concept}, regex, senders...}
  created_at timestamptz not null default now(),
  unique (user_id, bank_name, channel)
);
create index if not exists parsing_rules_user_id_idx
  on public.parsing_rules(user_id);

-- ---------------------------------------------------------------------
-- 5) BANK_CONNECTIONS: andamiaje para agregador (Belvo) — Premium futuro
--    Sin uso todavía; queda el esquema listo.
-- ---------------------------------------------------------------------
create table if not exists public.bank_connections (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  provider     text not null default 'belvo',
  external_id  text,                         -- link id del agregador
  institution  text,
  status       text not null default 'pending'
                 check (status in ('pending','active','error','revoked')),
  last_sync_at timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists bank_connections_user_id_idx
  on public.bank_connections(user_id);

-- =====================================================================
-- ROW LEVEL SECURITY (dueño por user_id)
-- =====================================================================
alter table public.statement_imports enable row level security;
alter table public.import_staging     enable row level security;
alter table public.parsing_rules      enable row level security;
alter table public.bank_connections   enable row level security;

drop policy if exists statement_imports_all_own on public.statement_imports;
create policy statement_imports_all_own on public.statement_imports
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists import_staging_all_own on public.import_staging;
create policy import_staging_all_own on public.import_staging
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists parsing_rules_all_own on public.parsing_rules;
create policy parsing_rules_all_own on public.parsing_rules
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists bank_connections_all_own on public.bank_connections;
create policy bank_connections_all_own on public.bank_connections
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- =====================================================================
-- VISTAS DE SALDO: excluir movimientos PENDIENTES (aún sin confirmar)
-- Se recrean para que sms/email en estado pending no alteren saldos.
-- =====================================================================
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
        where t.account_id = a.id and t.kind = 'income'   and t.pending = false), 0)
    - coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.kind = 'expense'  and t.pending = false), 0)
    - coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.kind = 'transfer' and t.pending = false), 0)
    + coalesce((select sum(t.amount) from public.transactions t
        where t.to_account_id = a.id and t.kind = 'transfer' and t.pending = false), 0)
  as current_balance
from public.accounts a;

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
      where t.card_id = c.id and t.kind = 'expense' and t.pending = false), 0) as used,
  coalesce(c.credit_limit, 0)
    - coalesce((select sum(t.amount) from public.transactions t
        where t.card_id = c.id and t.kind = 'expense' and t.pending = false), 0) as available
from public.cards c
where c.type = 'credit';

grant select on public.account_balances to authenticated;
grant select on public.card_usage       to authenticated;
