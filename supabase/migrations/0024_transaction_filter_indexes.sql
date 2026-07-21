-- Índices para los filtros de la pantalla de Transacciones.
--
-- La búsqueda libre usa ILIKE '%texto%' sobre concept y notes. Un B-tree no
-- sirve para un patrón con comodín al inicio, así que hace falta un índice
-- trigram (pg_trgm); sin él la búsqueda degrada a seq scan sobre todo el
-- histórico del usuario.
--
-- category_id además nunca tuvo índice, aunque ya es FK y ahora se filtra por
-- ella con .in(). Ver 0001_init.sql, que sí indexó account_id/card_id/tx_date.

create extension if not exists pg_trgm;

create index if not exists transactions_concept_trgm_idx
  on transactions using gin (concept gin_trgm_ops);

create index if not exists transactions_notes_trgm_idx
  on transactions using gin (notes gin_trgm_ops);

create index if not exists transactions_category_id_idx
  on transactions (category_id);
