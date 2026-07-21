-- =====================================================================
-- Ahorbit — MVP 5: configuración global de premium y límites (editable por
-- admin). Por ahora TODO gratis: límites en 0 (ilimitado) y features no premium.
-- Un admin puede endurecer límites y marcar features como premium después.
-- Re-ejecutable.
-- =====================================================================

-- Tabla de una sola fila (id boolean fijo en true).
create table if not exists public.app_config (
  id                         boolean primary key default true check (id),
  free_max_accounts          int not null default 0,  -- 0 = ilimitado
  free_max_cards             int not null default 0,
  free_max_transactions      int not null default 0,
  family_is_premium          boolean not null default false,
  yields_is_premium          boolean not null default false,
  installments_is_premium    boolean not null default false,
  reports_filters_is_premium boolean not null default false,
  updated_at                 timestamptz not null default now()
);

insert into public.app_config (id) values (true) on conflict (id) do nothing;

alter table public.app_config enable row level security;

-- Todos los usuarios autenticados leen la config (para saber sus límites).
drop policy if exists app_config_select on public.app_config;
create policy app_config_select on public.app_config for select using (true);

-- Solo admins editan.
drop policy if exists app_config_update on public.app_config;
create policy app_config_update on public.app_config for update
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

grant select, update on public.app_config to authenticated;

-- ---------------------------------------------------------------------
-- Crear familia: respeta el flag configurable. Si family_is_premium=false
-- (por defecto), cualquiera puede crear; si se marca premium, solo premium.
-- ---------------------------------------------------------------------
drop policy if exists families_insert on public.families;
create policy families_insert on public.families for insert with check (
  owner_id = auth.uid()
  and (
    coalesce((select not family_is_premium from public.app_config limit 1), false)
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_premium)
  )
);
