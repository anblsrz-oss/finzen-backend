-- =====================================================================
-- Ahorbit — Tarjetas físicas y virtuales.
-- El formato es independiente del tipo: hay tarjetas virtuales tanto de
-- débito como de crédito. Una tarjeta virtual no trae marca impresa, así
-- que en ese caso `brand` queda null y la UI muestra un distintivo
-- "Virtual" en lugar del logo de la red.
-- `brand` sigue siendo texto libre para permitir la opción "Otro"; la UI
-- normaliza los valores conocidos (ver src/lib/cardBrands.ts).
-- Re-ejecutable.
-- =====================================================================
alter table public.cards
  add column if not exists card_format text not null default 'physical';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'cards_card_format_check'
  ) then
    alter table public.cards
      add constraint cards_card_format_check
      check (card_format in ('physical', 'virtual'));
  end if;
end $$;
