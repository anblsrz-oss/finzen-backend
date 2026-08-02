-- El constraint transactions_transfer_shape se creó directamente en producción
-- (sin migración registrada) y exigía to_account_id NOT NULL para TODA
-- transferencia, sin excepción para is_external = true. Desde que 0026
-- introdujo is_external (transferencia a cuenta externa, con to_account_id
-- nulo por diseño), esto rompía cualquier transferencia externa.

alter table public.transactions
  drop constraint if exists transactions_transfer_shape;

alter table public.transactions
  add constraint transactions_transfer_shape check (
    kind <> 'transfer'::tx_kind
    or (
      account_id is not null
      and (
        (is_external and to_account_id is null)
        or (not is_external and to_account_id is not null and account_id <> to_account_id)
      )
    )
  );
