-- ============================================================
-- 039 — SA1010 vira CADASTRO MESTRE da segmentação operacional
-- ============================================================
-- Contexto: até a 038 a base de clientes (`castor_clientes_derived_v2`) era
-- montada SÓ de SF2010∪SC5010 (atividade de venda). O SA1010 real só foi
-- ingerido agora (migration 037 + Source-Manager). Resultado: clientes
-- cadastrados que nunca compraram NÃO apareciam, e "ativo/inativo/reativação"
-- eram inferidos por RECÊNCIA de venda — ignorando as flags reais ATIVO/INATIVO
-- do cadastro Protheus.
--
-- Esta migração:
--   1) Reescreve `castor_clientes_derived_v2` → SA1010 como lista mestre de
--      clientes, UNIÃO com clientes que só aparecem em vendas (defensivo, p/ não
--      perder ninguém). Nome/vendedor vêm do SA1010 com fallback p/ vendas.
--   2) Reescreve `castor_client_metrics_v2` → mantém TODAS as colunas/ordem
--      anteriores (CREATE OR REPLACE compat), preenche endereço/UF/município com
--      fallback do SA1010 real, e ANEXA flags cadastrais + status combinado:
--        a1_ativo, a1_inativo, status_cadastral, elegivel_reativacao,
--        is_ativo_cadastro, a1_cgc, a1_pessoa, a1_risco, a1_lc, ramo_codigo,
--        ramo_desc, a1_bairro_cad, has_sa1010.
--      `status_real` (recência) é mantido como SINAL SECUNDÁRIO de priorização.
--   3) Reescreve `castor_admin_suggest_pool` → o bucket combina cadastro real
--      (a1_inativo/a1_ativo) com recência.
--
-- Regra de negócio (decidida 06/2026):
--   - elegivel_reativacao (verdade p/ tab Reativação):
--       cadastrado  → a1_inativo
--       só-vendas   → última atividade > 365 dias
--   - ativo = complemento (NÃO elegível p/ reativação) — preserva a semântica
--     histórica da tab Ativos (a1_ustatus <> '2').
--   - lead = ZA7010 sem correspondência no SA1010 real (e sem venda).
--
-- IDEMPOTENTE. Sem DROP/CASCADE. Sem TRUNCATE.
-- reversible: reaplicar 010+028+038.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Base mestre: SA1010 ∪ (clientes só de vendas)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW castor_clientes_derived_v2 AS
WITH sales AS (
  SELECT (f2_cliente || COALESCE(f2_loja,'')) AS cliente_codigo,
         f2_cliente AS cod, f2_loja AS loja,
         NULL::TEXT AS nome, NULL::TEXT AS vend, f2_emissao AS dt
    FROM castor_src_sf2010
   WHERE f2_cliente IS NOT NULL AND f2_cliente <> ''
  UNION ALL
  SELECT (c5_cliente || COALESCE(c5_loja,'')),
         c5_cliente, c5_loja, c5_nome, c5_vend, c5_emissao
    FROM castor_src_sc5010
   WHERE c5_cliente IS NOT NULL AND c5_cliente <> ''
),
sales_ranked AS (
  SELECT cliente_codigo, cod, loja, nome, vend,
         ROW_NUMBER() OVER (
           PARTITION BY cliente_codigo
           ORDER BY (nome IS NOT NULL AND btrim(nome) <> '') DESC,
                    (vend IS NOT NULL AND btrim(vend) <> '') DESC,
                    dt DESC NULLS LAST
         ) AS rn
    FROM sales
),
sales_best AS (
  SELECT cliente_codigo, cod, loja,
         NULLIF(btrim(nome),'') AS nome,
         NULLIF(btrim(vend),'') AS vend
    FROM sales_ranked
   WHERE rn = 1
),
cad AS (
  SELECT cliente_codigo,
         a1_cod  AS cod,
         a1_loja AS loja,
         NULLIF(btrim(a1_nome),'') AS nome,
         NULLIF(btrim(a1_vend),'') AS vend
    FROM castor_src_sa1010
   WHERE cliente_codigo IS NOT NULL AND btrim(cliente_codigo) <> ''
),
all_codes AS (
  SELECT cliente_codigo FROM cad
  UNION
  SELECT cliente_codigo FROM sales_best
)
SELECT
  ac.cliente_codigo,
  COALESCE(c.cod,  sb.cod)  AS a1_cod,
  COALESCE(c.loja, sb.loja) AS a1_loja,
  COALESCE(c.nome, sb.nome) AS a1_nome,
  COALESCE(c.vend, sb.vend) AS a1_vend
FROM all_codes ac
LEFT JOIN cad        c  ON c.cliente_codigo  = ac.cliente_codigo
LEFT JOIN sales_best sb ON sb.cliente_codigo = ac.cliente_codigo;

-- ------------------------------------------------------------
-- 2) View MASTER de métricas + flags cadastrais SA1010
--    As 34 primeiras colunas preservam nome/ordem/tipo da 028
--    (CREATE OR REPLACE só permite ANEXAR colunas no fim).
--    Endereço/UF/município ganham fallback do SA1010 real.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW castor_client_metrics_v2 AS
SELECT
  d.cliente_codigo,
  d.a1_cod,
  d.a1_loja,
  d.a1_nome,
  d.a1_vend,
  v.a3_nome      AS vendedor_nome,
  v.a3_nreduz    AS vendedor_nreduz,
  COALESCE(NULLIF(btrim(addr.endereco),''),  NULLIF(btrim(s.a1_end),''))  AS a1_end,
  COALESCE(NULLIF(btrim(addr.cep),''),       NULLIF(btrim(s.a1_cep),''))  AS a1_cep,
  COALESCE(NULLIF(btrim(addr.municipio),''), NULLIF(btrim(s.a1_mun),''))  AS a1_mun,
  COALESCE(NULLIF(btrim(addr.uf),''),        NULLIF(btrim(s.a1_est),''))  AS a1_est,
  addr.endereco_source,
  addr.lifecycle_status,
  COALESCE(f12.faturamento_12m, 0)   AS faturamento_12m,
  COALESCE(f12.pedidos_12m, 0)       AS pedidos_12m,
  COALESCE(f12.ticket_medio_12m, 0)  AS ticket_medio_12m,
  COALESCE(fa.faturamento_alltime, 0)  AS faturamento_alltime,
  COALESCE(fa.pedidos_alltime, 0)      AS pedidos_alltime,
  COALESCE(fa.ticket_medio_alltime, 0) AS ticket_medio_alltime,
  fa.primeira_nota,
  fa.ultima_nota,
  fa.primeiro_pedido,
  fa.ultimo_pedido,
  fa.ultima_atividade,
  CASE WHEN fa.ultima_atividade IS NOT NULL
       THEN (CURRENT_DATE - fa.ultima_atividade)::INT
       ELSE NULL END AS dias_sem_atividade,
  CASE WHEN fa.ultimo_pedido IS NOT NULL
       THEN (CURRENT_DATE - fa.ultimo_pedido)::INT
       ELSE NULL END AS dias_sem_pedido,
  CASE
    WHEN addr.lifecycle_status = 'encerrado'                       THEN 'ENCERRADO'
    WHEN addr.lifecycle_status = 'nao_interessado_permanente'      THEN 'NAO_INTERESSADO'
    WHEN fa.ultima_atividade IS NULL                               THEN 'SEM_HISTORICO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '90 days')  THEN 'ATIVO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '180 days') THEN 'EM_RISCO'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '365 days') THEN 'REATIVAR'
    WHEN fa.ultima_atividade >= (CURRENT_DATE - INTERVAL '730 days') THEN 'INATIVO'
    ELSE 'DORMENTE'
  END AS status_real,
  CASE
    WHEN COALESCE(f12.ticket_medio_12m,0) > 0 THEN
      CASE WHEN f12.ticket_medio_12m < 3000  THEN 'pequeno'
           WHEN f12.ticket_medio_12m <= 10000 THEN 'medio'
           ELSE 'grande' END
    WHEN COALESCE(fa.ticket_medio_alltime,0) > 0 THEN
      CASE WHEN fa.ticket_medio_alltime < 3000  THEN 'pequeno'
           WHEN fa.ticket_medio_alltime <= 10000 THEN 'medio'
           ELSE 'grande' END
    ELSE 'desconhecido'
  END AS porte_efetivo,
  CASE
    WHEN COALESCE(f12.ticket_medio_12m,0)     > 0 THEN 'historico_12m'
    WHEN COALESCE(fa.ticket_medio_alltime,0)  > 0 THEN 'historico_alltime'
    ELSE 'sem_dados'
  END AS porte_origem,
  LEAST(100, GREATEST(0,
    COALESCE((CURRENT_DATE - fa.ultima_atividade)::INT / 4, 0)
    + CASE WHEN COALESCE(fa.faturamento_alltime,0) > 50000 THEN 10 ELSE 0 END
  ))::INT AS urgencia_score,
  addr.contato_nome,
  addr.contato_tel,
  addr.contato_whats,
  addr.contato_email,
  -- ==== colunas NOVAS (anexadas) — cadastro real SA1010 ====
  COALESCE(s.a1_ativo,   FALSE)                           AS a1_ativo,
  COALESCE(s.a1_inativo, FALSE)                           AS a1_inativo,
  CASE
    WHEN s.cliente_codigo IS NULL THEN 'sem_cadastro'
    WHEN s.a1_inativo             THEN 'inativo'
    WHEN s.a1_ativo               THEN 'ativo'
    ELSE 'indefinido'
  END                                                     AS status_cadastral,
  -- VERDADE p/ tab Reativação: cadastrado→a1_inativo; só-vendas→>365d s/ atividade
  CASE
    WHEN s.cliente_codigo IS NOT NULL THEN COALESCE(s.a1_inativo, FALSE)
    ELSE (fa.ultima_atividade IS NOT NULL
          AND fa.ultima_atividade < (CURRENT_DATE - INTERVAL '365 days'))
  END                                                     AS elegivel_reativacao,
  COALESCE(s.a1_ativo, FALSE)                             AS is_ativo_cadastro,
  s.a1_cgc,
  s.a1_pessoa,
  s.a1_risco,
  s.a1_lc,
  s.a1_sativ1                                             AS ramo_codigo,
  x.x5_descri                                             AS ramo_desc,
  NULLIF(btrim(s.a1_bairro),'')                          AS a1_bairro_cad,
  (s.cliente_codigo IS NOT NULL)                          AS has_sa1010
FROM castor_clientes_derived_v2 d
LEFT JOIN castor_client_address addr ON addr.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_metrics_alltime fa  ON fa.cliente_codigo  = d.cliente_codigo
LEFT JOIN castor_client_metrics f12  ON f12.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_src_sa3010 v        ON v.a3_cod = d.a1_vend
LEFT JOIN castor_src_sa1010 s        ON s.cliente_codigo = d.cliente_codigo
LEFT JOIN castor_src_sx5010 x        ON x.x5_chave = s.a1_sativ1 AND x.x5_tabela = 'T3';

-- ------------------------------------------------------------
-- 3) Suggest pool — bucket combina cadastro real + recência
--    (idêntico à 038, só o CASE de bucket muda)
-- ------------------------------------------------------------
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

  WITH base AS (
    SELECT m.*, g.lat AS gc_lat, g.lng AS gc_lng,
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
  SELECT jsonb_agg(row_obj ORDER BY bucket_rank, urg DESC NULLS LAST, fat DESC NULLS LAST),
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
                                       NULLIF(btrim(contato_email),'')) IS NULL)
      ) AS row_obj,
      CASE bucket
        WHEN 'reativacao' THEN 1
        WHEN 'ativo_bom'  THEN 2
        WHEN 'prospect'   THEN 3
        ELSE 9
      END AS bucket_rank,
      urgencia_score AS urg,
      faturamento_alltime AS fat,
      bucket, lvl
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
      COUNT(*) FILTER (WHERE (value->>'bucket') = 'ativo_bom')
      INTO v_n_react, v_n_prosp, v_n_ativo
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
    'open_excluded',    COALESCE(array_length(v_engaged_codes,1), 0),
    'engaged_excluded', COALESCE(array_length(v_engaged_codes,1), 0),
    'engagement_scope', 'global'
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_suggest_pool(UUID, UUID, TEXT[], INT)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('039_sa1010_master_segments') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
