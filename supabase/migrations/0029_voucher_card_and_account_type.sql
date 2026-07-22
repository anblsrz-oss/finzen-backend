-- Vales de despensa: nuevo tipo de tarjeta y de cuenta. Se comportan como
-- débito (saldo prepago ligado a una cuenta). ADD VALUE IF NOT EXISTS es
-- idempotente por si la migración se reaplica.
ALTER TYPE card_type ADD VALUE IF NOT EXISTS 'voucher';
ALTER TYPE account_type ADD VALUE IF NOT EXISTS 'voucher';
