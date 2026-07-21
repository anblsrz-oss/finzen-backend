-- Ahorbit — Fase: captura de tickets por OCR.
-- Permite 'receipt' como origen de transacción. Re-ejecutable.

alter table public.transactions drop constraint if exists transactions_source_chk;
alter table public.transactions add constraint transactions_source_chk
  check (source in ('manual','import','email','sms','aggregator','receipt'));
