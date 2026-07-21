-- Ahorbit — Plan familiar (Premium).
-- El jefe de familia (premium) comparte tarjetas de crédito propias; los
-- miembros registran gastos en ellas. El límite de crédito SOLO lo ve el dueño.
-- Los gastos familiares viven aparte de las finanzas personales de cada quien.
-- Re-ejecutable (idempotente).

-- =========================================================================
-- 1) Tablas
-- =========================================================================

create table if not exists public.families (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade,
  name       text not null default 'Mi familia',
  created_at timestamptz not null default now()
);
-- Una familia por dueño (v1).
create unique index if not exists families_owner_uidx on public.families(owner_id);

create table if not exists public.family_members (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references public.families(id) on delete cascade,
  -- null hasta que el invitado acepta
  user_id       uuid references auth.users(id) on delete cascade,
  invited_email text not null check (position('@' in invited_email) > 1),
  status        text not null default 'pending'
                  check (status in ('pending','accepted','rejected')),
  invited_at    timestamptz not null default now(),
  responded_at  timestamptz,
  unique (family_id, invited_email)
);
create index if not exists family_members_email_idx on public.family_members (lower(invited_email));
create index if not exists family_members_user_idx  on public.family_members (user_id);

create table if not exists public.family_shared_cards (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  card_id    uuid not null references public.cards(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (family_id, card_id)
);

alter table public.transactions
  add column if not exists family_id uuid references public.families(id) on delete set null;
create index if not exists transactions_family_idx
  on public.transactions(family_id) where family_id is not null;

-- =========================================================================
-- 2) Helpers security definer.
-- Corren como el dueño de la función (bypass RLS) => las políticas de
-- family_members pueden consultar family_members SIN recursión.
-- OJO: nunca aplicar `force row level security` a estas tablas.
-- =========================================================================

create or replace function public.jwt_email() returns text
language sql stable as
$$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function public.is_family_owner(fid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from families f where f.id = fid and f.owner_id = auth.uid()) $$;

create or replace function public.is_family_member(fid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from family_members m
                  where m.family_id = fid and m.user_id = auth.uid()
                    and m.status = 'accepted') $$;

create or replace function public.has_family_invite(fid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from family_members m
                  where m.family_id = fid
                    and lower(m.invited_email) = public.jwt_email()
                    and m.status = 'pending') $$;

revoke execute on function public.is_family_owner(uuid) from anon;
revoke execute on function public.is_family_member(uuid) from anon;
revoke execute on function public.has_family_invite(uuid) from anon;

-- =========================================================================
-- 3) RLS
-- =========================================================================

alter table public.families            enable row level security;
alter table public.family_members      enable row level security;
alter table public.family_shared_cards enable row level security;

-- FAMILIES ---------------------------------------------------------------
drop policy if exists families_select on public.families;
create policy families_select on public.families for select using (
  owner_id = auth.uid()
  or public.is_family_member(id)
  or public.has_family_invite(id)
);

-- Crear familia requiere Premium (gate en servidor, no solo UI).
drop policy if exists families_insert on public.families;
create policy families_insert on public.families for insert with check (
  owner_id = auth.uid()
  and exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_premium)
);

drop policy if exists families_update on public.families;
create policy families_update on public.families for update
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists families_delete on public.families;
create policy families_delete on public.families for delete using (owner_id = auth.uid());

-- FAMILY_MEMBERS ----------------------------------------------------------
drop policy if exists family_members_select on public.family_members;
create policy family_members_select on public.family_members for select using (
  user_id = auth.uid()
  or lower(invited_email) = public.jwt_email()
  or public.is_family_owner(family_id)
  or public.is_family_member(family_id)
);

drop policy if exists family_members_insert on public.family_members;
create policy family_members_insert on public.family_members for insert with check (
  public.is_family_owner(family_id) and status = 'pending' and user_id is null
);

drop policy if exists family_members_update_owner on public.family_members;
create policy family_members_update_owner on public.family_members for update
  using (public.is_family_owner(family_id))
  with check (public.is_family_owner(family_id));

-- El invitado solo puede responder su propia invitación pendiente.
drop policy if exists family_members_update_invitee on public.family_members;
create policy family_members_update_invitee on public.family_members for update
  using (lower(invited_email) = public.jwt_email() and status = 'pending')
  with check (
    lower(invited_email) = public.jwt_email()
    and (user_id is null or user_id = auth.uid())
    and status in ('accepted','rejected')
  );

drop policy if exists family_members_delete on public.family_members;
create policy family_members_delete on public.family_members for delete using (
  public.is_family_owner(family_id) or user_id = auth.uid()
);

-- FAMILY_SHARED_CARDS -----------------------------------------------------
drop policy if exists family_shared_cards_select on public.family_shared_cards;
create policy family_shared_cards_select on public.family_shared_cards for select using (
  public.is_family_owner(family_id) or public.is_family_member(family_id)
);

-- Solo el dueño de la familia puede compartir, y solo tarjetas SUYAS.
drop policy if exists family_shared_cards_insert on public.family_shared_cards;
create policy family_shared_cards_insert on public.family_shared_cards for insert with check (
  public.is_family_owner(family_id)
  and exists (select 1 from public.cards c where c.id = card_id and c.user_id = auth.uid())
);

drop policy if exists family_shared_cards_delete on public.family_shared_cards;
create policy family_shared_cards_delete on public.family_shared_cards for delete
  using (public.is_family_owner(family_id));

-- TRANSACTIONS ------------------------------------------------------------
-- Política ADITIVA de lectura: los miembros/dueño ven las tx familiares.
-- (La escritura se valida con trigger; ver abajo.)
drop policy if exists transactions_select_family on public.transactions;
create policy transactions_select_family on public.transactions for select using (
  family_id is not null
  and (public.is_family_member(family_id) or public.is_family_owner(family_id))
);

-- =========================================================================
-- 4) Trigger de validación de escritura familiar.
-- Las políticas RLS se OR-ean, así que la política *_all_own ya permite
-- insertar cualquier fila propia; un family_id forjado solo se frena aquí.
-- =========================================================================

create or replace function public.validate_family_tx() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.family_id is not null then
    if not (public.is_family_member(new.family_id) or public.is_family_owner(new.family_id)) then
      raise exception 'No perteneces a esta familia';
    end if;
    if new.kind <> 'expense' then
      raise exception 'Solo egresos pueden ser gastos familiares';
    end if;
    if new.card_id is null or not exists (
      select 1 from family_shared_cards fsc
      where fsc.family_id = new.family_id and fsc.card_id = new.card_id
    ) then
      raise exception 'La tarjeta no está compartida con esta familia';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists transactions_family_check on public.transactions;
create trigger transactions_family_check
  before insert or update of family_id, card_id on public.transactions
  for each row execute function public.validate_family_tx();

-- =========================================================================
-- 5) Vistas seguras para miembros.
-- SEGURIDAD: estas vistas son security DEFINER (default de Postgres) a
-- propósito: corren como su dueño y el WHERE de pertenencia ES el control de
-- acceso. NUNCA:
--   - agregarles credit_limit / cut_day / payment_day / account_id
--     (el requisito es que los miembros NO vean el límite del dueño)
--   - marcarlas security_invoker = true (rompería el acceso de los miembros)
-- =========================================================================

create or replace view public.family_cards
  with (security_barrier = true) as
select fsc.family_id, fsc.card_id, c.name, c.brand, c.type, c.currency,
       c.user_id as owner_id
from public.family_shared_cards fsc
join public.cards c on c.id = fsc.card_id
where public.is_family_owner(fsc.family_id) or public.is_family_member(fsc.family_id);

create or replace view public.family_card_usage
  with (security_barrier = true) as
select fsc.family_id, fsc.card_id, c.name, c.currency,
       coalesce(sum(t.amount) filter (where t.kind = 'expense' and t.pending = false), 0)
         as family_spent
from public.family_shared_cards fsc
join public.cards c on c.id = fsc.card_id
left join public.transactions t
  on t.card_id = fsc.card_id and t.family_id = fsc.family_id
where public.is_family_owner(fsc.family_id) or public.is_family_member(fsc.family_id)
group by fsc.family_id, fsc.card_id, c.name, c.currency;

-- profiles es select-own; esta vista expone solo nombre/avatar DENTRO de la
-- familia (para mostrar quién hizo cada gasto).
create or replace view public.family_member_profiles
  with (security_barrier = true) as
select m.family_id, m.id as member_id, m.user_id, m.invited_email, m.status,
       p.full_name, p.avatar_url
from public.family_members m
left join public.profiles p on p.id = m.user_id
where public.is_family_owner(m.family_id)
   or public.is_family_member(m.family_id)
   or lower(m.invited_email) = public.jwt_email();

revoke all on public.family_cards from anon;
revoke all on public.family_card_usage from anon;
revoke all on public.family_member_profiles from anon;
grant select on public.family_cards, public.family_card_usage,
  public.family_member_profiles to authenticated;
