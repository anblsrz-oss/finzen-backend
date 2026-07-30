-- =====================================================================
-- Limpieza de falsos positivos de la sincronización de correo.
--
-- El parseo compartido (functions/_shared/parseEmail.ts) trataba la regla de
-- remitente como opcional (`rule?.config ?? {}`) y gmail-push no filtraba por
-- remitente en absoluto, así que cualquier correo del buzón con un número de
-- dos decimales —incluido el CSS del HTML— se registraba como egreso pendiente.
--
-- Aquí se borran esas transacciones dejando el rastro en transaction_deletions,
-- igual que haría delete_transaction_with_reason. No se puede reusar esa función
-- porque es `security invoker` y depende de auth.uid(), que en una migración es
-- null; se replica su mapeo de columnas con un insert ... select + delete.
--
-- Alcance: solo pending = true. Las transacciones de correo ya confirmadas por
-- el usuario no se tocan. Re-ejecutable (el delete la hace idempotente).
-- =====================================================================

begin;

insert into public.transaction_deletions (
  user_id, transaction_id, kind, amount, currency, concept,
  account_id, to_account_id, card_id, tx_date, source, reason, snapshot
)
select
  t.user_id, t.id, t.kind, t.amount, t.currency, t.concept,
  t.account_id, t.to_account_id, t.card_id, t.tx_date, t.source,
  'Limpieza: falsos positivos de sincronización de correo (filtro de remitente ausente)',
  to_jsonb(t)
from public.transactions t
where t.source = 'email'
  and t.pending = true;

delete from public.transactions
where source = 'email'
  and pending = true;

commit;
