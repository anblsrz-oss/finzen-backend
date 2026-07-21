-- =====================================================================
-- Ahorbit — Historial de eliminación de transacciones (Fase 8.1)
-- Al eliminar una transacción se guarda un snapshot + motivo en una tabla de
-- auditoría y luego se borra la transacción. El balance (vista account_balances)
-- se revierte automáticamente porque deja de sumar la transacción borrada.
-- Re-ejecutable.
-- =====================================================================

-- 1) Tabla de auditoría de eliminaciones.
create table if not exists public.transaction_deletions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  transaction_id uuid not null,               -- id original (ya no existe en transactions)
  kind           text,
  amount         numeric(14,2),
  currency       text,
  concept        text,
  account_id     uuid,
  to_account_id  uuid,
  card_id        uuid,
  tx_date        date,
  source         text,
  reason         text not null,
  snapshot       jsonb,                        -- copia completa de la fila original
  deleted_at     timestamptz not null default now()
);
create index if not exists transaction_deletions_user_id_idx
  on public.transaction_deletions(user_id);
create index if not exists transaction_deletions_deleted_at_idx
  on public.transaction_deletions(user_id, deleted_at desc);

-- 2) RLS: cada quien ve/gestiona su propio historial.
alter table public.transaction_deletions enable row level security;
drop policy if exists transaction_deletions_all_own on public.transaction_deletions;
create policy transaction_deletions_all_own on public.transaction_deletions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 3) Función atómica: registra el snapshot + motivo y borra la transacción.
--    security invoker => respeta la RLS del usuario (solo borra lo suyo).
create or replace function public.delete_transaction_with_reason(
  p_tx_id uuid,
  p_reason text
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  t public.transactions;
begin
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'El motivo de eliminación es obligatorio';
  end if;

  select * into t
  from public.transactions
  where id = p_tx_id and user_id = auth.uid();

  if not found then
    raise exception 'Transacción no encontrada o sin permiso';
  end if;

  insert into public.transaction_deletions (
    user_id, transaction_id, kind, amount, currency, concept,
    account_id, to_account_id, card_id, tx_date, source, reason, snapshot
  ) values (
    t.user_id, t.id, t.kind, t.amount, t.currency, t.concept,
    t.account_id, t.to_account_id, t.card_id, t.tx_date, t.source,
    btrim(p_reason), to_jsonb(t)
  );

  delete from public.transactions where id = t.id;
end $$;

grant execute on function public.delete_transaction_with_reason(uuid, text) to authenticated;
