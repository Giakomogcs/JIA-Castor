-- ============================================================
-- 041 — Fix: "Próximos contatos" continua em ATRASO após resolver o card
-- ============================================================
-- Bug reportado (vendedor): registrei uma interação no card ATRASADO, setei o
-- próximo contato para +30 dias (ou marquei como resolvido/convertido) e mesmo
-- assim o sidebar ("Atrasados" + card "Próximos contatos") continua dizendo que
-- o cliente está atrasado.
--
-- Causa raiz — `castor_client_pending_followups` (migration 015):
--   WITH last_per_client AS (
--     SELECT DISTINCT ON (cliente_codigo) ...
--       FROM castor_client_interactions
--      WHERE next_contact_at IS NOT NULL        -- ❌ filtra ANTES do DISTINCT ON
--      ORDER BY cliente_codigo, occurred_at DESC
--   )
--   O filtro `next_contact_at IS NOT NULL` era aplicado ANTES de escolher a
--   última interação. Quando a interação MAIS RECENTE zera o agendamento
--   (outcome terminal — convertido/nao_existe_mais/nao_interessado_permanente —
--   o backend força next_contact_at = NULL), essa linha era descartada e o
--   DISTINCT ON "caía de volta" na interação ANTIGA e vencida. Resultado: o
--   cliente já resolvido reaparecia eternamente como atrasado.
--   (Também havia não-determinismo quando duas interações tinham o mesmo
--    occurred_at: o desempate era arbitrário e podia escolher a antiga.)
--
-- Correção:
--   1) Escolher a interação GENUINAMENTE mais recente por cliente (sem o filtro
--      de next_contact_at dentro do DISTINCT ON), com desempate determinístico
--      (occurred_at DESC, created_at DESC, id DESC).
--   2) Só DEPOIS exigir `next_contact_at IS NOT NULL` no WHERE externo. Se a
--      última interação não tem próximo contato (foi resolvida/terminal), o
--      cliente NÃO aparece mais na fila — que é o comportamento correto.
--
-- Mantém assinatura, colunas, ordem e GRANTs idênticos à 015.
-- IDEMPOTENTE. Sem DROP/CASCADE. Sem TRUNCATE.
-- reversible: reaplicar 015.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION castor_client_pending_followups(
  p_user_id     UUID,
  p_days_ahead  INT,         -- janela futura (0=apenas vencidos+hoje)
  p_limit       INT
) RETURNS TABLE(
  cliente_codigo  TEXT,
  cliente_nome    TEXT,
  municipio       TEXT,
  uf              TEXT,
  contato_tel     TEXT,
  contato_whats   TEXT,
  contato_email   TEXT,
  next_contact_at DATE,
  dias_para       INT,
  last_outcome    TEXT,
  last_type       TEXT,
  last_notes      TEXT,
  vendedor_user_id UUID
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_is_admin BOOLEAN;
  v_cap_date DATE;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  v_cap_date := CURRENT_DATE + (GREATEST(0, COALESCE(p_days_ahead,0)) || ' days')::INTERVAL;

  RETURN QUERY
  WITH last_per_client AS (
    -- Interação GENUINAMENTE mais recente por cliente (sem pré-filtrar por
    -- next_contact_at). Desempate determinístico para evitar "voltar" p/ a antiga.
    SELECT DISTINCT ON (cliente_codigo)
           cliente_codigo, vendedor_user_id, interaction_type, outcome, notes,
           next_contact_at, occurred_at
      FROM castor_client_interactions
     ORDER BY cliente_codigo, occurred_at DESC, created_at DESC, id DESC
  )
  SELECT
    l.cliente_codigo,
    m.a1_nome,
    m.a1_mun,
    m.a1_est,
    m.contato_tel,
    m.contato_whats,
    m.contato_email,
    l.next_contact_at,
    (l.next_contact_at - CURRENT_DATE)::INT AS dias_para,
    l.outcome,
    l.interaction_type,
    l.notes,
    l.vendedor_user_id
  FROM last_per_client l
  LEFT JOIN castor_client_metrics_v2 m ON m.cliente_codigo = l.cliente_codigo
  WHERE l.next_contact_at IS NOT NULL          -- só agenda se a ÚLTIMA interação tem próximo contato
    AND l.next_contact_at <= v_cap_date
    AND (v_is_admin OR l.vendedor_user_id = p_user_id)
    AND COALESCE(m.lifecycle_status,'ativo') NOT IN ('encerrado','nao_interessado_permanente')
  ORDER BY l.next_contact_at ASC NULLS LAST
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit,100), 500));
END; $$;
GRANT EXECUTE ON FUNCTION castor_client_pending_followups(UUID,INT,INT) TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('041_pending_followups_latest_fix') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
