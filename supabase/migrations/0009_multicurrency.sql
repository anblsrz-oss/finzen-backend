-- =====================================================================
-- Ahorbit — Multimoneda: moneda principal + tipo de cambio (fix de balance)
-- Antes, las vistas de saldo y los reportes sumaban `amount` ignorando la
-- moneda, así que un gasto en USD se sumaba como si fuera MXN. Ahora cada
-- transacción guarda `base_amount` (convertida a la moneda principal del
-- usuario) y las agregaciones usan ese valor.
-- Re-ejecutable (IF NOT EXISTS / DROP ... IF EXISTS / bloques DO).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) PROFILES: moneda principal del usuario.
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists main_currency text not null default 'MXN';

-- ---------------------------------------------------------------------
-- 2) TRANSACTIONS: tipo de cambio y monto convertido a la moneda principal.
--    base_amount = amount * fx_rate  (fx_rate = 1 cuando la moneda coincide)
-- ---------------------------------------------------------------------
alter table public.transactions
  add column if not exists fx_rate     numeric,
  add column if not exists base_amount numeric(14,2);

-- Backfill: los movimientos existentes se asumen en la moneda principal.
update public.transactions
  set base_amount = amount, fx_rate = 1
  where base_amount is null;

-- Red de seguridad: cualquier inserción/actualización sin base_amount (imports,
-- correo, sms, recibos que aún no calculan conversión) cae a fx=1 / base=amount.
-- Así ningún flujo deja base_amount en null y los reportes quedan consistentes.
create or replace function public.fill_tx_base_amount() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.fx_rate is null then new.fx_rate := 1; end if;
  if new.base_amount is null then new.base_amount := new.amount; end if;
  return new;
end $$;

revoke execute on function public.fill_tx_base_amount() from anon, authenticated, public;

drop trigger if exists transactions_fill_base_amount on public.transactions;
create trigger transactions_fill_base_amount
  before insert or update of amount, fx_rate, base_amount on public.transactions
  for each row execute function public.fill_tx_base_amount();

-- ---------------------------------------------------------------------
-- 3) FX_RATES: caché de tipos de cambio (una fila por fecha+par).
--    La edge function fx-rate la llena (service_role); el cliente solo lee.
-- ---------------------------------------------------------------------
create table if not exists public.fx_rates (
  rate_date  date not null,
  base       text not null,
  quote      text not null,
  rate       numeric not null,
  fetched_at timestamptz not null default now(),
  primary key (rate_date, base, quote)
);

alter table public.fx_rates enable row level security;

drop policy if exists fx_rates_select on public.fx_rates;
create policy fx_rates_select on public.fx_rates for select using (true);

grant select on public.fx_rates to authenticated;

-- ---------------------------------------------------------------------
-- 4) PROFILES: permitir que el usuario edite SU perfil (p. ej. main_currency,
--    full_name) sin poder auto-asignarse is_premium / is_admin.
--    Un trigger congela las columnas privilegiadas salvo para service_role
--    (la edge function set-premium sigue funcionando).
-- ---------------------------------------------------------------------
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

create or replace function public.protect_profile_privileged_cols() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Solo el service_role (edge functions con service key) puede tocar estas
  -- columnas. Cualquier otro rol las conserva con su valor anterior.
  if coalesce(auth.role(), '') <> 'service_role' then
    new.is_premium := old.is_premium;
    new.is_admin   := old.is_admin;
    new.id         := old.id;
    new.email      := old.email;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;

-- El event trigger del proyecto otorga EXECUTE a anon/authenticated en cada
-- función nueva; como esta es solo de trigger, se revoca (no debe llamarse por RPC).
revoke execute on function public.protect_profile_privileged_cols() from anon, authenticated, public;

drop trigger if exists profiles_protect_privileged on public.profiles;
create trigger profiles_protect_privileged
  before update on public.profiles
  for each row execute function public.protect_profile_privileged_cols();

-- ---------------------------------------------------------------------
-- 5) VISTAS DE SALDO: convertir a la moneda de la cuenta/tarjeta.
--    Regla: si la moneda del movimiento == moneda de la cuenta, usar amount;
--    si no, usar base_amount (correcto cuando la cuenta está en la moneda
--    principal, que es el caso común). Se conserva pending = false.
-- ---------------------------------------------------------------------
drop view if exists public.account_balances;
create view public.account_balances
  with (security_invoker = true) as
select
  a.id            as account_id,
  a.user_id,
  a.name,
  a.currency,
  a.initial_balance
    + coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.account_id = a.id and t.kind = 'income'   and t.pending = false), 0)
    - coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.account_id = a.id and t.kind = 'expense'  and t.pending = false), 0)
    - coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.account_id = a.id and t.kind = 'transfer' and t.pending = false), 0)
    + coalesce((select sum(case when t.currency = a.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
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
  coalesce((select sum(case when t.currency = c.currency then t.amount
                            else coalesce(t.base_amount, t.amount) end)
      from public.transactions t
      where t.card_id = c.id and t.kind = 'expense' and t.pending = false), 0) as used,
  coalesce(c.credit_limit, 0)
    - coalesce((select sum(case when t.currency = c.currency then t.amount
                                else coalesce(t.base_amount, t.amount) end)
        from public.transactions t
        where t.card_id = c.id and t.kind = 'expense' and t.pending = false), 0) as available
from public.cards c
where c.type = 'credit';

grant select on public.account_balances to authenticated;
grant select on public.card_usage       to authenticated;
