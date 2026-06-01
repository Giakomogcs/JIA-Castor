-- ============================================================
-- 042 — Suggest pool: marcar/priorizar por histórico de interação
-- ============================================================
-- Pedido do usuário (admin, modal "Sugestões da IA → enviar para vendedor"):
--   * Hoje as sugestões não têm NENHUMA marca visual indicando que a empresa
--     JÁ TEVE interações (logo, já passou pela carteira de algum vendedor).
--   * Empresa que ESTÁ em carteira/fluxo de alguém NÃO pode ser sugerida de novo
--     — nem para o mesmo vendedor (já está com ele) nem para outro (já tem
--     alguém cuidando). [Isso já é garantido desde a 038/039 via v_engaged_codes
--     GLOBAL — mantido intacto aqui.]
--   * Só volta a ser sugerível quando SAIU de toda carteira (nenhum fluxo aberto
--     em ninguém). [Também já é a semântica do v_engaged_codes.]
--   * PRIORIZAR quem ainda NÃO tem interação nenhuma (empresa "virgem") na frente
--     de quem já foi trabalhada antes.
--
-- O que esta migração acrescenta (a exclusão global continua igual à 039):
--   1) CTE `hist` agrega castor_client_interactions por cliente → contagem total
--      de toques (history_count), data/outcome da última interação e o último
--      vendedor que tocou (user_id → label via auth.users; fallback codigo).
--      OBS: castor_client_interactions cobre TANTO interações avulsas quanto as
--      ligadas a roteiro (route_id), então é o "tocou alguma vez" completo.
--   2) row_obj ganha: has_history, history_count, history_vendor,
--      last_interaction_outcome, last_interaction_at.
--   3) Ordenação passa a colocar quem NÃO tem histórico (has_history=false)
--      SEMPRE na frente; dentro de cada grupo mantém bucket_rank → urgência →
--      faturamento (idêntico à 039).
--
-- Mantém assinatura, GRANTs, exclusão global (v_engaged_codes) e demais campos
-- idênticos à 039. CREATE OR REPLACE — NUNCA DROP/CASCADE. Idempotente.
-- reversible: reaplicar 039.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION castor_admin_suggest_pool(
  p_caller         UUID,
  p_target_user_id UUID,
  p_exclude_codes  TEXT[] DEFAULT NULL,
  p_limit          INT    DEFAULT 30
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_vend          TEXT;
  v_est           TEXT[];
  v_cid           TEXT[];
  v_role          TEXT;
  v_engaged_codes TEXT[];
  v_rows          JSONB;
  v_lim           INT;
  v_scope_used    TEXT;
  v_n_react INT := 0; v_n_prosp INT := 0; v_n_ativo INT := 0;
  v_n_virgin INT := 0; v_n_worked INT := 0;
  v_terminal TEXT[] := ARRAY[
    'convertido','negativo','nao_existe_mais','nao_interessado_permanente'
  ];
  v_open_outcome TEXT[] := ARRAY[
    'voltar_depois','aguardando_resposta','pedido_em_negociacao','sem_contato'
  ];
BEGIN
  PERFORM castor_assert_admin(p_caller);

  IF p_target_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target_user_id obrigatorio');
  END IF;

  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_target_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','target nao existe');
  END IF;
  IF v_role = 'inactive' THEN
    RETURN jsonb_build_object('ok',false,'error','target inativo');
  END IF;

  SELECT s.vendor_code, s.estados, s.cidades
    INTO v_vend, v_est, v_cid
  FROM castor_user_scope(p_target_user_id) s;

  IF v_est IS NOT NULL AND array_length(v_est, 1) IS NULL THEN v_est := NULL; END IF;
  IF v_cid IS NOT NULL AND array_length(v_cid, 1) IS NULL THEN v_cid := NULL; END IF;
  IF v_vend IS NOT NULL AND btrim(v_vend) = '' THEN v_vend := NULL; END IF;

  -- --------------------------------------------------------
  -- Engajamento GLOBAL (idêntico à 038/039): empresa "em fluxo" de QUALQUER
  -- consultor é excluída — está em carteira de alguém, não re-sugerir.
  -- --------------------------------------------------------
  WITH
  route_codes AS (
    SELECT DISTINCT NULLIF(btrim(st->>'cliente_codigo'), '') AS code
      FROM castor_route_saved r
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.stops, '[]'::jsonb)) AS st
     WHERE r.status IN ('planejado','em_andamento')
       AND NULLIF(btrim(st->>'cliente_codigo'), '') IS NOT NULL
       AND COALESCE(NULLIF(btrim(st->>'outcome'), ''), '') <> ALL (v_terminal)
  ),
  last_interaction AS (
    SELECT DISTINCT ON (i.cliente_codigo)
           i.cliente_codigo, i.outcome
      FROM castor_client_interactions i
     WHERE i.route_id IS NULL
       AND i.cliente_codigo IS NOT NULL
     ORDER BY i.cliente_codigo, i.occurred_at DESC
  ),
  kanban_codes AS (
    SELECT cliente_codigo AS code
      FROM last_interaction
     WHERE outcome IS NULL
        OR outcome = ANY (v_open_outcome)
  )
  SELECT COALESCE(array_agg(DISTINCT code), ARRAY[]::TEXT[])
    INTO v_engaged_codes
    FROM (
      SELECT code FROM route_codes
      UNION
      SELECT code FROM kanban_codes
    ) u
   WHERE code IS NOT NULL;

  v_lim := GREATEST(5, LEAST(COALESCE(p_limit, 30), 100));

  WITH
  -- Histórico de toques (qualquer interação, avulsa ou de roteiro) por cliente.
  -- Usado p/ a TAG visual e p/ priorizar quem nunca foi trabalhado.
  hist AS (
    SELECT
      i.cliente_codigo,
      COUNT(*)::int AS history_count,
      MAX(i.occurred_at) AS last_at,
      (ARRAY_AGG(i.outcome ORDER BY i.occurred_at DESC NULLS LAST, i.created_at DESC))[1]           AS last_outcome,
      (ARRAY_AGG(i.vendedor_user_id ORDER BY i.occurred_at DESC NULLS LAST, i.created_at DESC))[1]  AS last_vendor_user_id,
      (ARRAY_AGG(NULLIF(btrim(i.vendedor_codigo),'') ORDER BY i.occurred_at DESC NULLS LAST, i.created_at DESC))[1] AS last_vendor_codigo
    FROM castor_client_interactions i
    WHERE i.cliente_codigo IS NOT NULL
    GROUP BY i.cliente_codigo
  ),
  base AS (
    SELECT m.*, g.lat AS gc_lat, g.lng AS gc_lng,
      COALESCE(h.history_count, 0)                       AS hist_count,
      (COALESCE(h.history_count, 0) > 0)                 AS has_history,
      h.last_at                                          AS hist_last_at,
      h.last_outcome                                     AS hist_last_outcome,
      COALESCE(uh.full_label, h.last_vendor_codigo)      AS hist_vendor_label,
      CASE
        -- REATIVAÇÃO: cadastro inativo (verdade) OU recência ruim, mas COM histórico.
        WHEN (COALESCE(m.elegivel_reativacao, FALSE)
              OR m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE'))
             AND m.pedidos_alltime >= 1                          THEN 'reativacao'
        -- PROSPECT: sem histórico de pedido (inclui cadastrados que nunca compraram).
        WHEN m.status_real = 'SEM_HISTORICO'
             OR m.pedidos_alltime = 0                            THEN 'prospect'
        -- ATIVO BOM: cadastro ativo OU atividade recente, com porte relevante.
        WHEN (COALESCE(m.is_ativo_cadastro, FALSE) OR m.status_real = 'ATIVO')
             AND m.porte_efetivo IN ('medio','grande')           THEN 'ativo_bom'
        ELSE NULL
      END AS bucket
    FROM castor_client_metrics_v2 m
    LEFT JOIN castor_geocode_cache g
      ON g.scope = 'municipio'
     AND g.query_key = upper(coalesce(m.a1_mun,'')) || '|' || upper(coalesce(m.a1_est,''))
     AND g.ok
    LEFT JOIN hist h
      ON h.cliente_codigo = m.cliente_codigo
    LEFT JOIN LATERAL (
      SELECT COALESCE(u.raw_user_meta_data->>'full_name',
                      u.raw_user_meta_data->>'name',
                      u.email) AS full_label
        FROM auth.users u
       WHERE u.id = h.last_vendor_user_id
    ) uh ON TRUE
    WHERE COALESCE(m.lifecycle_status, '') NOT IN ('encerrado','nao_interessado_permanente')
      AND (p_exclude_codes IS NULL OR NOT (m.cliente_codigo = ANY(p_exclude_codes)))
      AND NOT (m.cliente_codigo = ANY(v_engaged_codes))
  ),
  lvl_a AS (
    SELECT * FROM base
     WHERE bucket IS NOT NULL
       AND (v_vend IS NULL OR a1_vend = v_vend)
       AND (v_est  IS NULL OR upper(coalesce(a1_est,'')) = ANY(v_est))
       AND (v_cid  IS NULL OR upper(coalesce(a1_mun,'')) = ANY(v_cid))
  ),
  lvl_b AS (
    SELECT * FROM base
     WHERE bucket IS NOT NULL
       AND (v_est IS NULL OR upper(coalesce(a1_est,'')) = ANY(v_est))
       AND (v_cid IS NULL OR upper(coalesce(a1_mun,'')) = ANY(v_cid))
  ),
  lvl_c AS (
    SELECT * FROM base WHERE bucket IS NOT NULL
  ),
  picked AS (
    SELECT *, 'A'::text AS lvl FROM lvl_a
    UNION ALL
    SELECT *, 'B'::text FROM lvl_b WHERE NOT EXISTS (SELECT 1 FROM lvl_a)
    UNION ALL
    SELECT *, 'C'::text FROM lvl_c WHERE NOT EXISTS (SELECT 1 FROM lvl_a)
                                     AND NOT EXISTS (SELECT 1 FROM lvl_b)
  )
  SELECT jsonb_agg(row_obj ORDER BY hist_rank, bucket_rank, urg DESC NULLS LAST, fat DESC NULLS LAST),
         MAX(lvl)
    INTO v_rows, v_scope_used
  FROM (
    SELECT
      jsonb_build_object(
        'cliente_codigo',    cliente_codigo,
        'a1_nome',           a1_nome,
        'a1_vend',           a1_vend,
        'vendedor_nome',     vendedor_nome,
        'a1_end',            a1_end,
        'a1_cep',            a1_cep,
        'a1_mun',            a1_mun,
        'a1_est',            a1_est,
        'contato_nome',      contato_nome,
        'contato_tel',       contato_tel,
        'contato_whats',     contato_whats,
        'contato_email',     contato_email,
        'status_real',       status_real,
        'status_cadastral',  status_cadastral,
        'elegivel_reativacao', elegivel_reativacao,
        'urgencia_score',    urgencia_score,
        'porte_efetivo',     porte_efetivo,
        'faturamento_alltime', faturamento_alltime,
        'ultimo_pedido',     ultimo_pedido,
        'dias_sem_pedido',   dias_sem_pedido,
        'bucket',            bucket,
        'lat',               gc_lat,
        'lng',               gc_lng,
        'has_geocode',       (gc_lat IS NOT NULL AND gc_lng IS NOT NULL),
        'missing_address',   (a1_end IS NULL OR btrim(a1_end) = ''),
        'missing_contact',   (COALESCE(NULLIF(btrim(contato_tel),''),
                                       NULLIF(btrim(contato_whats),''),
                                       NULLIF(btrim(contato_email),'')) IS NULL),
        -- NOVO: histórico de interação (tag visual + prioridade)
        'has_history',       has_history,
        'history_count',     hist_count,
        'history_vendor',    hist_vendor_label,
        'last_interaction_outcome', hist_last_outcome,
        'last_interaction_at',      hist_last_at
      ) AS row_obj,
      -- quem NUNCA foi trabalhado vem primeiro (0), trabalhados depois (1)
      CASE WHEN has_history THEN 1 ELSE 0 END AS hist_rank,
      CASE bucket
        WHEN 'reativacao' THEN 1
        WHEN 'ativo_bom'  THEN 2
        WHEN 'prospect'   THEN 3
        ELSE 9
      END AS bucket_rank,
      urgencia_score AS urg,
      faturamento_alltime AS fat,
      bucket, lvl, has_history
    FROM picked
  ) ranked;

  IF v_rows IS NOT NULL AND jsonb_array_length(v_rows) > v_lim THEN
    SELECT jsonb_agg(value)
      INTO v_rows
      FROM (
        SELECT value
          FROM jsonb_array_elements(v_rows) WITH ORDINALITY t(value, ord)
         ORDER BY ord
         LIMIT v_lim
      ) sub;
  END IF;

  IF v_rows IS NOT NULL THEN
    SELECT
      COUNT(*) FILTER (WHERE (value->>'bucket') = 'reativacao'),
      COUNT(*) FILTER (WHERE (value->>'bucket') = 'prospect'),
      COUNT(*) FILTER (WHERE (value->>'bucket') = 'ativo_bom'),
      COUNT(*) FILTER (WHERE (value->>'has_history') = 'false'),
      COUNT(*) FILTER (WHERE (value->>'has_history') = 'true')
      INTO v_n_react, v_n_prosp, v_n_ativo, v_n_virgin, v_n_worked
    FROM jsonb_array_elements(v_rows);
  END IF;

  RETURN jsonb_build_object(
    'ok',            true,
    'target_user_id',p_target_user_id,
    'vendor_code',   v_vend,
    'scope_estados', COALESCE(to_jsonb(v_est), 'null'::jsonb),
    'scope_cidades', COALESCE(to_jsonb(v_cid), 'null'::jsonb),
    'scope_used',    COALESCE(v_scope_used, 'none'),
    'pool',          COALESCE(v_rows, '[]'::jsonb),
    'pool_size',     COALESCE(jsonb_array_length(v_rows), 0),
    'by_bucket',     jsonb_build_object(
                       'reativacao', v_n_react,
                       'prospect',   v_n_prosp,
                       'ativo_bom',  v_n_ativo
                     ),
    'by_history',    jsonb_build_object(
                       'virgin', v_n_virgin,   -- nunca trabalhados (prioridade)
                       'worked', v_n_worked    -- já tiveram interação antes
                     ),
    'open_excluded',    COALESCE(array_length(v_engaged_codes,1), 0),
    'engaged_excluded', COALESCE(array_length(v_engaged_codes,1), 0),
    'engagement_scope', 'global'
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_suggest_pool(UUID, UUID, TEXT[], INT)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('042_suggest_pool_history_tag') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
