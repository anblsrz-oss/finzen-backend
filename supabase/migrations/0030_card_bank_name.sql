-- Banco al que pertenece la tarjeta (texto libre, opcional). Independiente de
-- brand (visa/mastercard). Permite agrupar tarjetas por banco.
ALTER TABLE public.cards ADD COLUMN IF NOT EXISTS bank_name text;
