-- file: 037_products_items_time.sql
-- tier: A
-- purpose:
--   Traz para dentro da aplicação as fontes Protheus que antes ficavam só no Drive:
--     * SA1010 (cadastro REAL de cliente — substitui derivação) → castor_src_sa1010
--     * SB1010 (produtos) + SBM010 (grupos)                     → castor_src_sb1010 / _sbm010
--     * SD2010 (itens de NF — base de mix/faturamento de venda)  → castor_src_sd2010
--     * SF4010 (TES/CFOP) + SX5010 (tabelas genéricas, ramo)     → castor_src_sf4010 / _sx5010
--     * SZ1010 (status do cliente antes/depois da venda)         → castor_src_sz1010
--
--   Agregados novos (refresh após ingest de SD2010):
--     * castor_metrics_produto_cliente — o que cada cliente compra (top produtos)
--     * castor_metrics_produto         — ranking global de produtos
--     * castor_metrics_grupo           — ranking global de grupos
--     * castor_metrics_mensal          — faturamento de venda mês a mês (por cliente)
--     * castor_metrics_venda_cliente   — faturamento de VENDA real (CFOP-filtrado) vs bonificação/devolução
--
--   Função castor_cfop_class() classifica D2_CF em venda/bonificacao/devolucao/transferencia/outro.
--
--   View castor_cliente_enriquecido — junta SA1010 (status ATIVO/INATIVO, ramo, endereço real)
--   sobre castor_client_metrics_v2 (sem reescrever a v2 — adoção incremental).
--
--   RPCs novas para o agente/front (todas com escopo admin/vendedor):
--     castor_product_mix, castor_top_products, castor_top_groups,
--     castor_monthly_trend, castor_crosssell, castor_client_status_history
--
--   castor_admin_sources_status() é recriada incluindo as novas tabelas.
--
-- depends: 001, 004, 005/008 (sources+metrics), 010 (v2), 013 (user_scope)
-- reversible: yes (DOWN comentado no rodapé)
-- IDEMPOTENTE. Sem CASCADE.

BEGIN;

-- ============================================================
-- 1) SA1010 — cadastro REAL de clientes
--    Extrato custom (xlsx COM header). A1_CODCLI = COD(6)+LOJA(2).
--    Status vem das flags ATIVO/INATIVO (não há A1_USTATUS neste extrato).
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sa1010 (
  id             BIGSERIAL PRIMARY KEY,
  a1_codcli_raw  TEXT,               -- A1_CODCLI cru (cod+loja concatenados)
  a1_nome        TEXT,
  a1_nreduz      TEXT,
  a1_pessoa      TEXT,               -- F=física, J=jurídica
  a1_cgc         TEXT,               -- CNPJ/CPF
  a1_pricom      DATE,               -- primeira compra
  a1_ultcom      DATE,               -- última compra
  a1_vend        TEXT,               -- A3_COD do vendedor
  a1_risco       TEXT,               -- A=OK B/C/D=risco E=manual
  a1_lc          NUMERIC(14,2),      -- limite de crédito
  a1_sativ1      TEXT,               -- ramo de atividade (FK SX5 tabela 'T3')
  a1_end         TEXT,
  a1_cep         TEXT,
  a1_bairro      TEXT,
  a1_est         TEXT,
  a1_cod_mun     TEXT,
  a1_mun         TEXT,
  a1_ativo_raw   TEXT,               -- flag ATIVO ('1'/'0')
  a1_inativo_raw TEXT,               -- flag INATIVO ('1'/'0')
  -- derivados (preenchidos por castor_refresh_sa1010_derived)
  cliente_codigo TEXT,               -- a1_cod || lpad(loja,2,'0')
  a1_cod         TEXT,
  a1_loja        TEXT,
  a1_ativo       BOOLEAN DEFAULT FALSE,
  a1_inativo     BOOLEAN DEFAULT FALSE,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_src_sa1010_code_idx ON castor_src_sa1010(cliente_codigo);
CREATE INDEX IF NOT EXISTS castor_src_sa1010_vend_idx ON castor_src_sa1010(a1_vend);
CREATE INDEX IF NOT EXISTS castor_src_sa1010_inativo_idx ON castor_src_sa1010(a1_inativo);
CREATE INDEX IF NOT EXISTS castor_src_sa1010_mun_idx ON castor_src_sa1010(a1_est, a1_cod_mun);
CREATE INDEX IF NOT EXISTS castor_src_sa1010_ramo_idx ON castor_src_sa1010(a1_sativ1);

-- Deriva cliente_codigo / cod / loja / flags a partir das colunas cruas.
-- Chamado pelo Source-Manager após cada ingest de SA1010.
CREATE OR REPLACE FUNCTION castor_refresh_sa1010_derived()
RETURNS INT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_rows INT;
BEGIN
  UPDATE castor_src_sa1010 SET
    a1_cod  = substr(a1_codcli_raw, 1, 6),
    a1_loja = COALESCE(NULLIF(lpad(NULLIF(btrim(substr(a1_codcli_raw, 7)), ''), 2, '0'), ''), '01'),
    cliente_codigo = substr(a1_codcli_raw, 1, 6)
                     || COALESCE(NULLIF(lpad(NULLIF(btrim(substr(a1_codcli_raw, 7)), ''), 2, '0'), ''), '01'),
    a1_ativo   = (btrim(COALESCE(a1_ativo_raw, ''))   = '1'),
    a1_inativo = (btrim(COALESCE(a1_inativo_raw, '')) = '1')
  WHERE a1_codcli_raw IS NOT NULL AND btrim(a1_codcli_raw) <> '';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;
GRANT EXECUTE ON FUNCTION castor_refresh_sa1010_derived() TO authenticated, service_role;

-- ============================================================
-- 2) SB1010 — produtos (cadastro mestre)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sb1010 (
  b1_cod      TEXT PRIMARY KEY,
  b1_desc     TEXT,
  b1_tipo     TEXT,
  b1_um       TEXT,
  b1_grupo    TEXT,
  b1_prv1     NUMERIC(14,2),
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_src_sb1010_grupo_idx ON castor_src_sb1010(b1_grupo);

-- ============================================================
-- 3) SBM010 — grupos de produto
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sbm010 (
  bm_grupo    TEXT PRIMARY KEY,
  bm_desc     TEXT,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 4) SD2010 — itens de NF de saída (uma linha por item faturado)
--    Base de mix de produtos e faturamento de VENDA.
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sd2010 (
  id          BIGSERIAL PRIMARY KEY,
  d2_item     TEXT,
  d2_cod      TEXT,        -- produto (= B1_COD)
  d2_quant    NUMERIC(18,4) DEFAULT 0,
  d2_prcven   NUMERIC(18,6) DEFAULT 0,
  d2_total    NUMERIC(14,2) DEFAULT 0,
  d2_descon   NUMERIC(14,2) DEFAULT 0,
  d2_tes      TEXT,        -- = F4_CODIGO
  d2_cf       TEXT,        -- CFOP
  d2_pedido   TEXT,        -- = C5_NUM / C6_NUM
  d2_cliente  TEXT,
  d2_loja     TEXT,
  d2_doc      TEXT,        -- nº NF
  d2_serie    TEXT,
  d2_grupo    TEXT,        -- = B1_GRUPO
  d2_emissao  DATE,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_src_sd2010_cli_idx  ON castor_src_sd2010(d2_cliente, d2_loja);
CREATE INDEX IF NOT EXISTS castor_src_sd2010_prod_idx ON castor_src_sd2010(d2_cod);
CREATE INDEX IF NOT EXISTS castor_src_sd2010_grp_idx  ON castor_src_sd2010(d2_grupo);
CREATE INDEX IF NOT EXISTS castor_src_sd2010_emis_idx ON castor_src_sd2010(d2_emissao DESC);
CREATE INDEX IF NOT EXISTS castor_src_sd2010_cf_idx   ON castor_src_sd2010(d2_cf);

-- ============================================================
-- 5) SF4010 — TES (Tipos de Entrada e Saída) / CFOP padrão
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sf4010 (
  f4_codigo   TEXT PRIMARY KEY,
  f4_tipo     TEXT,        -- E/S
  f4_cf       TEXT,        -- CFOP padrão
  f4_texto    TEXT,        -- descrição
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 6) SX5010 — tabelas genéricas (ramo de atividade etc.)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sx5010 (
  x5_tabela   TEXT NOT NULL,
  x5_chave    TEXT NOT NULL,
  x5_descri   TEXT,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (x5_tabela, x5_chave)
);

-- ============================================================
-- 7) SZ1010 — status do cliente antes/depois da venda (custom)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_src_sz1010 (
  id          BIGSERIAL PRIMARY KEY,
  z1_cod      TEXT,
  z1_clicod   TEXT,
  z1_loja     TEXT,
  z1_statua   TEXT,        -- status antes
  z1_statud   TEXT,        -- status depois
  z1_riscoa   TEXT,
  z1_riscod   TEXT,
  z1_tpalt    TEXT,
  z1_pedido   TEXT,
  z1_usunom   TEXT,
  z1_data     DATE,
  z1_hora     TEXT,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_src_sz1010_cli_idx ON castor_src_sz1010(z1_clicod, z1_loja);
CREATE INDEX IF NOT EXISTS castor_src_sz1010_data_idx ON castor_src_sz1010(z1_data DESC);

-- ============================================================
-- 8) Classificador de CFOP (D2_CF) — separa venda real do resto
-- ============================================================
CREATE OR REPLACE FUNCTION castor_cfop_class(p_cf TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_cf IS NULL OR btrim(p_cf) = '' THEN 'outro'
    -- bonificação / brinde / doação / amostra (saída 5910/6910 e família 59/69)
    WHEN btrim(p_cf) ~ '^[56]9' THEN 'bonificacao'
    -- devolução / retorno (entradas 1xxx/2xxx, ou 5202/6202)
    WHEN btrim(p_cf) ~ '^[12]'  THEN 'devolucao'
    WHEN btrim(p_cf) IN ('5202','6202','5411','6411') THEN 'devolucao'
    -- transferência entre filiais/estoque
    WHEN btrim(p_cf) IN ('5151','5152','6151','6152','5408','5409','6408','6409') THEN 'transferencia'
    -- venda de mercadoria (5.10x/6.10x) e venda c/ ST (5.40x/6.40x)
    WHEN btrim(p_cf) ~ '^[56]10' THEN 'venda'
    WHEN btrim(p_cf) ~ '^[56]40' THEN 'venda'
    WHEN btrim(p_cf) ~ '^[56]11' THEN 'venda'
    WHEN btrim(p_cf) ~ '^[56]12' THEN 'venda'
    ELSE 'outro'
  END;
$$;
GRANT EXECUTE ON FUNCTION castor_cfop_class(TEXT) TO authenticated, service_role;

-- ============================================================
-- 9) AGREGADOS (preenchidos por castor_refresh_metrics_sd2)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_metrics_produto_cliente (
  cliente_codigo TEXT NOT NULL,
  produto        TEXT NOT NULL,
  b1_desc        TEXT,
  grupo          TEXT,
  grupo_desc     TEXT,
  qtd_total      NUMERIC(18,4) NOT NULL DEFAULT 0,
  valor_total    NUMERIC(14,2) NOT NULL DEFAULT 0,
  n_notas        INT NOT NULL DEFAULT 0,
  primeira_compra DATE,
  ultima_compra  DATE,
  computed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (cliente_codigo, produto)
);
CREATE INDEX IF NOT EXISTS castor_mpc_cli_idx ON castor_metrics_produto_cliente(cliente_codigo, valor_total DESC);
CREATE INDEX IF NOT EXISTS castor_mpc_grp_idx ON castor_metrics_produto_cliente(grupo);

CREATE TABLE IF NOT EXISTS castor_metrics_produto (
  produto      TEXT PRIMARY KEY,
  b1_desc      TEXT,
  grupo        TEXT,
  grupo_desc   TEXT,
  qtd_total    NUMERIC(18,4) NOT NULL DEFAULT 0,
  valor_total  NUMERIC(14,2) NOT NULL DEFAULT 0,
  n_clientes   INT NOT NULL DEFAULT 0,
  ultima_venda DATE,
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_mprod_val_idx ON castor_metrics_produto(valor_total DESC);
CREATE INDEX IF NOT EXISTS castor_mprod_grp_idx ON castor_metrics_produto(grupo);

CREATE TABLE IF NOT EXISTS castor_metrics_grupo (
  grupo        TEXT PRIMARY KEY,
  grupo_desc   TEXT,
  qtd_total    NUMERIC(18,4) NOT NULL DEFAULT 0,
  valor_total  NUMERIC(14,2) NOT NULL DEFAULT 0,
  n_clientes   INT NOT NULL DEFAULT 0,
  n_produtos   INT NOT NULL DEFAULT 0,
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_mgrp_val_idx ON castor_metrics_grupo(valor_total DESC);

-- faturamento de VENDA mês a mês (por cliente) — base da tendência
CREATE TABLE IF NOT EXISTS castor_metrics_mensal (
  cliente_codigo TEXT NOT NULL,
  ym             TEXT NOT NULL,   -- 'YYYY-MM'
  faturamento    NUMERIC(14,2) NOT NULL DEFAULT 0,
  qtd_itens      NUMERIC(18,4) NOT NULL DEFAULT 0,
  n_notas        INT NOT NULL DEFAULT 0,
  computed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (cliente_codigo, ym)
);
CREATE INDEX IF NOT EXISTS castor_mmes_ym_idx ON castor_metrics_mensal(ym);

-- faturamento de VENDA real (CFOP-filtrado) vs bonificação/devolução por cliente
CREATE TABLE IF NOT EXISTS castor_metrics_venda_cliente (
  cliente_codigo        TEXT PRIMARY KEY,
  fat_venda_12m         NUMERIC(14,2) NOT NULL DEFAULT 0,
  fat_venda_alltime     NUMERIC(14,2) NOT NULL DEFAULT 0,
  fat_bonificacao       NUMERIC(14,2) NOT NULL DEFAULT 0,
  fat_devolucao         NUMERIC(14,2) NOT NULL DEFAULT 0,
  itens_venda_12m       INT NOT NULL DEFAULT 0,
  ultima_venda          DATE,
  computed_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_mvc_fat_idx ON castor_metrics_venda_cliente(fat_venda_12m DESC);

-- ============================================================
-- 10) REFRESH dos agregados SD2 — chamado pelo Source-Manager
--     após cada ingest de SD2010.
-- ============================================================
CREATE OR REPLACE FUNCTION castor_refresh_metrics_sd2()
RETURNS INT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE v_rows INT;
BEGIN
  -- base: apenas itens de VENDA (CFOP de venda); guarda separado bonif/devol.
  -- produto x cliente (somente venda)
  TRUNCATE castor_metrics_produto_cliente;
  INSERT INTO castor_metrics_produto_cliente(
    cliente_codigo, produto, b1_desc, grupo, grupo_desc,
    qtd_total, valor_total, n_notas, primeira_compra, ultima_compra
  )
  SELECT (d.d2_cliente || COALESCE(d.d2_loja,'')) AS cliente_codigo,
         d.d2_cod AS produto,
         MAX(b.b1_desc) AS b1_desc,
         COALESCE(MAX(NULLIF(d.d2_grupo,'')), MAX(b.b1_grupo)) AS grupo,
         MAX(m.bm_desc) AS grupo_desc,
         ROUND(SUM(d.d2_quant)::NUMERIC, 4) AS qtd_total,
         ROUND(SUM(d.d2_total)::NUMERIC, 2) AS valor_total,
         COUNT(DISTINCT d.d2_doc) AS n_notas,
         MIN(d.d2_emissao) AS primeira_compra,
         MAX(d.d2_emissao) AS ultima_compra
    FROM castor_src_sd2010 d
    LEFT JOIN castor_src_sb1010 b ON b.b1_cod = d.d2_cod
    LEFT JOIN castor_src_sbm010 m ON m.bm_grupo = COALESCE(NULLIF(d.d2_grupo,''), b.b1_grupo)
   WHERE d.d2_cliente IS NOT NULL AND d.d2_cliente <> ''
     AND castor_cfop_class(d.d2_cf) = 'venda'
   GROUP BY 1, 2;

  -- ranking global de produtos
  TRUNCATE castor_metrics_produto;
  INSERT INTO castor_metrics_produto(produto, b1_desc, grupo, grupo_desc, qtd_total, valor_total, n_clientes, ultima_venda)
  SELECT produto,
         MAX(b1_desc),
         MAX(grupo),
         MAX(grupo_desc),
         ROUND(SUM(qtd_total)::NUMERIC, 4),
         ROUND(SUM(valor_total)::NUMERIC, 2),
         COUNT(DISTINCT cliente_codigo),
         MAX(ultima_compra)
    FROM castor_metrics_produto_cliente
   GROUP BY produto;

  -- ranking global de grupos
  TRUNCATE castor_metrics_grupo;
  INSERT INTO castor_metrics_grupo(grupo, grupo_desc, qtd_total, valor_total, n_clientes, n_produtos)
  SELECT COALESCE(NULLIF(grupo,''),'(sem grupo)'),
         MAX(grupo_desc),
         ROUND(SUM(qtd_total)::NUMERIC, 4),
         ROUND(SUM(valor_total)::NUMERIC, 2),
         COUNT(DISTINCT cliente_codigo),
         COUNT(DISTINCT produto)
    FROM castor_metrics_produto_cliente
   GROUP BY COALESCE(NULLIF(grupo,''),'(sem grupo)');

  -- tendência mensal (venda) por cliente
  TRUNCATE castor_metrics_mensal;
  INSERT INTO castor_metrics_mensal(cliente_codigo, ym, faturamento, qtd_itens, n_notas)
  SELECT (d2_cliente || COALESCE(d2_loja,'')) AS cliente_codigo,
         to_char(d2_emissao, 'YYYY-MM') AS ym,
         ROUND(SUM(d2_total)::NUMERIC, 2),
         ROUND(SUM(d2_quant)::NUMERIC, 4),
         COUNT(DISTINCT d2_doc)
    FROM castor_src_sd2010
   WHERE d2_cliente IS NOT NULL AND d2_cliente <> ''
     AND d2_emissao IS NOT NULL
     AND castor_cfop_class(d2_cf) = 'venda'
   GROUP BY 1, 2;

  -- faturamento venda vs bonificação vs devolução por cliente
  TRUNCATE castor_metrics_venda_cliente;
  INSERT INTO castor_metrics_venda_cliente(
    cliente_codigo, fat_venda_12m, fat_venda_alltime, fat_bonificacao, fat_devolucao, itens_venda_12m, ultima_venda
  )
  SELECT (d2_cliente || COALESCE(d2_loja,'')) AS cliente_codigo,
         ROUND(COALESCE(SUM(d2_total) FILTER (WHERE castor_cfop_class(d2_cf)='venda' AND d2_emissao >= CURRENT_DATE - INTERVAL '365 days'),0)::NUMERIC,2),
         ROUND(COALESCE(SUM(d2_total) FILTER (WHERE castor_cfop_class(d2_cf)='venda'),0)::NUMERIC,2),
         ROUND(COALESCE(SUM(d2_total) FILTER (WHERE castor_cfop_class(d2_cf)='bonificacao'),0)::NUMERIC,2),
         ROUND(COALESCE(SUM(d2_total) FILTER (WHERE castor_cfop_class(d2_cf)='devolucao'),0)::NUMERIC,2),
         COALESCE(COUNT(*) FILTER (WHERE castor_cfop_class(d2_cf)='venda' AND d2_emissao >= CURRENT_DATE - INTERVAL '365 days'),0)::INT,
         MAX(d2_emissao) FILTER (WHERE castor_cfop_class(d2_cf)='venda')
    FROM castor_src_sd2010
   WHERE d2_cliente IS NOT NULL AND d2_cliente <> ''
   GROUP BY 1;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;
GRANT EXECUTE ON FUNCTION castor_refresh_metrics_sd2() TO authenticated, service_role;

-- ============================================================
-- 11) VIEW: cliente enriquecido com SA1010 (status real, ramo, endereço)
--     Não reescreve v2 — adoção incremental pelo snapshot/agente.
-- ============================================================
CREATE OR REPLACE VIEW castor_cliente_enriquecido AS
SELECT
  m.cliente_codigo,
  COALESCE(NULLIF(BTRIM(s.a1_nome), ''), m.a1_nome)       AS nome,
  COALESCE(NULLIF(BTRIM(s.a1_vend), ''), m.a1_vend)       AS a1_vend,
  COALESCE(s.a1_est, m.a1_est)                            AS a1_est,
  COALESCE(NULLIF(BTRIM(s.a1_mun), ''), m.a1_mun)         AS a1_mun,
  s.a1_cgc,
  s.a1_pessoa,
  s.a1_risco,
  s.a1_lc,
  s.a1_sativ1                                             AS ramo_codigo,
  x.x5_descri                                             AS ramo_desc,
  s.a1_pricom,
  s.a1_ultcom,
  s.a1_ativo,
  s.a1_inativo,
  CASE
    WHEN s.cliente_codigo IS NULL          THEN 'sem_cadastro'
    WHEN s.a1_inativo                      THEN 'inativo'
    WHEN s.a1_ativo                        THEN 'ativo'
    ELSE 'indefinido'
  END                                                     AS status_sa1010,
  -- elegível para reativação = INATIVO segundo o cadastro real
  COALESCE(s.a1_inativo, FALSE)                           AS elegivel_reativacao,
  m.faturamento_12m,
  m.pedidos_12m,
  m.ticket_medio_12m,
  vc.fat_venda_12m,
  vc.fat_venda_alltime,
  vc.fat_bonificacao,
  vc.fat_devolucao,
  vc.ultima_venda
FROM castor_client_metrics_v2 m
LEFT JOIN castor_src_sa1010 s            ON s.cliente_codigo = m.cliente_codigo
LEFT JOIN castor_metrics_venda_cliente vc ON vc.cliente_codigo = m.cliente_codigo
-- Ramo de atividade do Protheus = tabela genérica 'T3' do SX5 (X5_CHAVE = A1_SATIV1)
LEFT JOIN castor_src_sx5010 x            ON x.x5_chave = s.a1_sativ1 AND x.x5_tabela = 'T3';

-- ============================================================
-- 12) RPCs para o agente / front (escopo admin/vendedor)
-- ============================================================

-- Mix de produtos de um cliente (top N por valor) + resumo de grupos
CREATE OR REPLACE FUNCTION castor_product_mix(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_limit          INT DEFAULT 15
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_scope    RECORD;
  v_a1_vend  TEXT;
  v_a1_est   TEXT;
  v_a1_mun   TEXT;
  v_visible  BOOLEAN;
  v_produtos JSONB;
  v_grupos   JSONB;
BEGIN
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cliente_codigo obrigatorio');
  END IF;
  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);

  SELECT m.a1_vend, m.a1_est, m.a1_mun
    INTO v_a1_vend, v_a1_est, v_a1_mun
    FROM castor_client_metrics_v2 m
   WHERE m.cliente_codigo = p_cliente_codigo
   LIMIT 1;

  IF v_scope.role = 'admin' THEN
    v_visible := TRUE;
  ELSE
    v_visible := (
      (v_scope.vendor_code IS NULL OR v_a1_vend = v_scope.vendor_code)
      AND (v_scope.estados IS NULL OR upper(coalesce(v_a1_est,'')) = ANY(v_scope.estados))
      AND (v_scope.cidades IS NULL OR upper(coalesce(v_a1_mun,'')) = ANY(v_scope.cidades))
    );
  END IF;
  IF NOT v_visible THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT COALESCE(jsonb_agg(t ORDER BY t.valor_total DESC), '[]'::jsonb) INTO v_produtos
  FROM (
    SELECT produto, b1_desc, grupo, grupo_desc, qtd_total, valor_total, n_notas, primeira_compra, ultima_compra
      FROM castor_metrics_produto_cliente
     WHERE cliente_codigo = p_cliente_codigo
     ORDER BY valor_total DESC
     LIMIT GREATEST(p_limit, 1)
  ) t;

  SELECT COALESCE(jsonb_agg(g ORDER BY g.valor_total DESC), '[]'::jsonb) INTO v_grupos
  FROM (
    SELECT COALESCE(NULLIF(grupo,''),'(sem grupo)') AS grupo,
           MAX(grupo_desc) AS grupo_desc,
           ROUND(SUM(valor_total)::NUMERIC,2) AS valor_total,
           ROUND(SUM(qtd_total)::NUMERIC,4) AS qtd_total,
           COUNT(*) AS n_produtos
      FROM castor_metrics_produto_cliente
     WHERE cliente_codigo = p_cliente_codigo
     GROUP BY COALESCE(NULLIF(grupo,''),'(sem grupo)')
  ) g;

  RETURN jsonb_build_object(
    'ok', true,
    'cliente_codigo', p_cliente_codigo,
    'produtos', v_produtos,
    'grupos', v_grupos
  );
END;
$$;
GRANT EXECUTE ON FUNCTION castor_product_mix(UUID, TEXT, INT) TO authenticated, service_role;

-- Ranking global de produtos (admin = tudo; vendedor = carteira dele)
CREATE OR REPLACE FUNCTION castor_top_products(
  p_user_id UUID,
  p_limit   INT DEFAULT 20,
  p_grupo   TEXT DEFAULT NULL
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_scope RECORD;
  v_rows  JSONB;
BEGIN
  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);

  IF v_scope.role = 'admin' THEN
    SELECT COALESCE(jsonb_agg(t ORDER BY t.valor_total DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT produto, b1_desc, grupo, grupo_desc, qtd_total, valor_total, n_clientes, ultima_venda
        FROM castor_metrics_produto
       WHERE (p_grupo IS NULL OR grupo = p_grupo)
       ORDER BY valor_total DESC
       LIMIT GREATEST(p_limit, 1)
    ) t;
  ELSE
    -- escopo do vendedor: agrega produto x cliente apenas dos clientes dele
    SELECT COALESCE(jsonb_agg(t ORDER BY t.valor_total DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT pc.produto, MAX(pc.b1_desc) AS b1_desc, MAX(pc.grupo) AS grupo,
             MAX(pc.grupo_desc) AS grupo_desc,
             ROUND(SUM(pc.qtd_total)::NUMERIC,4) AS qtd_total,
             ROUND(SUM(pc.valor_total)::NUMERIC,2) AS valor_total,
             COUNT(DISTINCT pc.cliente_codigo) AS n_clientes,
             MAX(pc.ultima_compra) AS ultima_venda
        FROM castor_metrics_produto_cliente pc
        JOIN castor_client_metrics_v2 m ON m.cliente_codigo = pc.cliente_codigo
       WHERE (v_scope.vendor_code IS NULL OR m.a1_vend = v_scope.vendor_code)
         AND (v_scope.estados IS NULL OR upper(coalesce(m.a1_est,'')) = ANY(v_scope.estados))
         AND (v_scope.cidades IS NULL OR upper(coalesce(m.a1_mun,'')) = ANY(v_scope.cidades))
         AND (p_grupo IS NULL OR pc.grupo = p_grupo)
       GROUP BY pc.produto
       ORDER BY valor_total DESC
       LIMIT GREATEST(p_limit, 1)
    ) t;
  END IF;

  RETURN jsonb_build_object('ok', true, 'produtos', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION castor_top_products(UUID, INT, TEXT) TO authenticated, service_role;

-- Ranking global de grupos
CREATE OR REPLACE FUNCTION castor_top_groups(
  p_user_id UUID,
  p_limit   INT DEFAULT 20
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_scope RECORD;
  v_rows  JSONB;
BEGIN
  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);

  IF v_scope.role = 'admin' THEN
    SELECT COALESCE(jsonb_agg(t ORDER BY t.valor_total DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT grupo, grupo_desc, qtd_total, valor_total, n_clientes, n_produtos
        FROM castor_metrics_grupo
       ORDER BY valor_total DESC
       LIMIT GREATEST(p_limit, 1)
    ) t;
  ELSE
    SELECT COALESCE(jsonb_agg(t ORDER BY t.valor_total DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT COALESCE(NULLIF(pc.grupo,''),'(sem grupo)') AS grupo,
             MAX(pc.grupo_desc) AS grupo_desc,
             ROUND(SUM(pc.qtd_total)::NUMERIC,4) AS qtd_total,
             ROUND(SUM(pc.valor_total)::NUMERIC,2) AS valor_total,
             COUNT(DISTINCT pc.cliente_codigo) AS n_clientes,
             COUNT(DISTINCT pc.produto) AS n_produtos
        FROM castor_metrics_produto_cliente pc
        JOIN castor_client_metrics_v2 m ON m.cliente_codigo = pc.cliente_codigo
       WHERE (v_scope.vendor_code IS NULL OR m.a1_vend = v_scope.vendor_code)
         AND (v_scope.estados IS NULL OR upper(coalesce(m.a1_est,'')) = ANY(v_scope.estados))
         AND (v_scope.cidades IS NULL OR upper(coalesce(m.a1_mun,'')) = ANY(v_scope.cidades))
       GROUP BY COALESCE(NULLIF(pc.grupo,''),'(sem grupo)')
       ORDER BY valor_total DESC
       LIMIT GREATEST(p_limit, 1)
    ) t;
  END IF;

  RETURN jsonb_build_object('ok', true, 'grupos', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION castor_top_groups(UUID, INT) TO authenticated, service_role;

-- Tendência mensal de faturamento (venda). p_cliente_codigo NULL = carteira/total.
CREATE OR REPLACE FUNCTION castor_monthly_trend(
  p_user_id        UUID,
  p_cliente_codigo TEXT DEFAULT NULL,
  p_months         INT  DEFAULT 24
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_scope RECORD;
  v_rows  JSONB;
  v_min   TEXT := to_char(CURRENT_DATE - (GREATEST(p_months,1) || ' months')::interval, 'YYYY-MM');
BEGIN
  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);

  IF p_cliente_codigo IS NOT NULL AND btrim(p_cliente_codigo) <> '' THEN
    SELECT COALESCE(jsonb_agg(t ORDER BY t.ym), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT ym, faturamento, qtd_itens, n_notas
        FROM castor_metrics_mensal
       WHERE cliente_codigo = p_cliente_codigo AND ym >= v_min
       ORDER BY ym
    ) t;
  ELSIF v_scope.role = 'admin' THEN
    SELECT COALESCE(jsonb_agg(t ORDER BY t.ym), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT ym, ROUND(SUM(faturamento)::NUMERIC,2) AS faturamento,
             ROUND(SUM(qtd_itens)::NUMERIC,4) AS qtd_itens,
             SUM(n_notas) AS n_notas
        FROM castor_metrics_mensal
       WHERE ym >= v_min
       GROUP BY ym ORDER BY ym
    ) t;
  ELSE
    SELECT COALESCE(jsonb_agg(t ORDER BY t.ym), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT mm.ym, ROUND(SUM(mm.faturamento)::NUMERIC,2) AS faturamento,
             ROUND(SUM(mm.qtd_itens)::NUMERIC,4) AS qtd_itens,
             SUM(mm.n_notas) AS n_notas
        FROM castor_metrics_mensal mm
        JOIN castor_client_metrics_v2 m ON m.cliente_codigo = mm.cliente_codigo
       WHERE mm.ym >= v_min
         AND (v_scope.vendor_code IS NULL OR m.a1_vend = v_scope.vendor_code)
         AND (v_scope.estados IS NULL OR upper(coalesce(m.a1_est,'')) = ANY(v_scope.estados))
         AND (v_scope.cidades IS NULL OR upper(coalesce(m.a1_mun,'')) = ANY(v_scope.cidades))
       GROUP BY mm.ym ORDER BY mm.ym
    ) t;
  END IF;

  RETURN jsonb_build_object('ok', true, 'cliente_codigo', p_cliente_codigo, 'serie', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION castor_monthly_trend(UUID, TEXT, INT) TO authenticated, service_role;

-- Sugestão de cross-sell: grupos que clientes do MESMO ramo compram e
-- que este cliente ainda NÃO compra (ordenados por penetração).
CREATE OR REPLACE FUNCTION castor_crosssell(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_limit          INT DEFAULT 8
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_scope    RECORD;
  v_a1_vend  TEXT;
  v_a1_est   TEXT;
  v_a1_mun   TEXT;
  v_ramo     TEXT;
  v_visible  BOOLEAN;
  v_rows     JSONB;
BEGIN
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cliente_codigo obrigatorio');
  END IF;
  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);

  SELECT m.a1_vend, m.a1_est, m.a1_mun
    INTO v_a1_vend, v_a1_est, v_a1_mun
    FROM castor_client_metrics_v2 m WHERE m.cliente_codigo = p_cliente_codigo LIMIT 1;

  IF v_scope.role = 'admin' THEN v_visible := TRUE;
  ELSE
    v_visible := (
      (v_scope.vendor_code IS NULL OR v_a1_vend = v_scope.vendor_code)
      AND (v_scope.estados IS NULL OR upper(coalesce(v_a1_est,'')) = ANY(v_scope.estados))
      AND (v_scope.cidades IS NULL OR upper(coalesce(v_a1_mun,'')) = ANY(v_scope.cidades))
    );
  END IF;
  IF NOT v_visible THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT a1_sativ1 INTO v_ramo FROM castor_src_sa1010 WHERE cliente_codigo = p_cliente_codigo;

  WITH peers AS (
    SELECT s.cliente_codigo
      FROM castor_src_sa1010 s
     WHERE v_ramo IS NOT NULL AND s.a1_sativ1 = v_ramo
       AND s.cliente_codigo <> p_cliente_codigo
  ),
  ja_compra AS (
    SELECT DISTINCT COALESCE(NULLIF(grupo,''),'(sem grupo)') AS grupo
      FROM castor_metrics_produto_cliente
     WHERE cliente_codigo = p_cliente_codigo
  ),
  sugest AS (
    SELECT COALESCE(NULLIF(pc.grupo,''),'(sem grupo)') AS grupo,
           MAX(pc.grupo_desc) AS grupo_desc,
           COUNT(DISTINCT pc.cliente_codigo) AS clientes_compram,
           ROUND(SUM(pc.valor_total)::NUMERIC,2) AS valor_total
      FROM castor_metrics_produto_cliente pc
     WHERE pc.cliente_codigo IN (SELECT cliente_codigo FROM peers)
       AND COALESCE(NULLIF(pc.grupo,''),'(sem grupo)') NOT IN (SELECT grupo FROM ja_compra)
     GROUP BY COALESCE(NULLIF(pc.grupo,''),'(sem grupo)')
  )
  SELECT COALESCE(jsonb_agg(t ORDER BY t.clientes_compram DESC, t.valor_total DESC), '[]'::jsonb) INTO v_rows
  FROM (SELECT * FROM sugest ORDER BY clientes_compram DESC, valor_total DESC LIMIT GREATEST(p_limit,1)) t;

  RETURN jsonb_build_object('ok', true, 'cliente_codigo', p_cliente_codigo, 'ramo', v_ramo, 'sugestoes', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION castor_crosssell(UUID, TEXT, INT) TO authenticated, service_role;

-- Histórico de mudança de status do cliente (SZ1010)
CREATE OR REPLACE FUNCTION castor_client_status_history(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_limit          INT DEFAULT 30
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_scope   RECORD;
  v_a1_vend TEXT; v_a1_est TEXT; v_a1_mun TEXT; v_visible BOOLEAN;
  v_cod     TEXT; v_loja TEXT; v_rows JSONB;
BEGIN
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cliente_codigo obrigatorio');
  END IF;
  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);
  SELECT m.a1_vend, m.a1_est, m.a1_mun INTO v_a1_vend, v_a1_est, v_a1_mun
    FROM castor_client_metrics_v2 m WHERE m.cliente_codigo = p_cliente_codigo LIMIT 1;

  IF v_scope.role = 'admin' THEN v_visible := TRUE;
  ELSE
    v_visible := (
      (v_scope.vendor_code IS NULL OR v_a1_vend = v_scope.vendor_code)
      AND (v_scope.estados IS NULL OR upper(coalesce(v_a1_est,'')) = ANY(v_scope.estados))
      AND (v_scope.cidades IS NULL OR upper(coalesce(v_a1_mun,'')) = ANY(v_scope.cidades))
    );
  END IF;
  IF NOT v_visible THEN RETURN jsonb_build_object('ok', false, 'error', 'forbidden'); END IF;

  v_cod  := substr(p_cliente_codigo, 1, 6);
  v_loja := NULLIF(btrim(substr(p_cliente_codigo, 7, 2)), '');

  SELECT COALESCE(jsonb_agg(t ORDER BY t.z1_data DESC, t.z1_hora DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT z1_data, z1_hora, z1_statua, z1_statud, z1_riscoa, z1_riscod, z1_pedido, z1_usunom
      FROM castor_src_sz1010
     WHERE z1_clicod = v_cod AND (v_loja IS NULL OR z1_loja = v_loja)
     ORDER BY z1_data DESC, z1_hora DESC
     LIMIT GREATEST(p_limit, 1)
  ) t;

  RETURN jsonb_build_object('ok', true, 'cliente_codigo', p_cliente_codigo, 'historico', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION castor_client_status_history(UUID, TEXT, INT) TO authenticated, service_role;

-- ============================================================
-- 13) castor_admin_sources_status() — incluir novas tabelas
-- ============================================================
CREATE OR REPLACE FUNCTION castor_admin_sources_status()
RETURNS TABLE(
  table_name       TEXT,
  rows_count       BIGINT,
  last_ingest_at   TIMESTAMPTZ,
  last_rows_in     INT,
  last_rows_out    INT,
  last_duration_ms INT,
  last_ok          BOOLEAN,
  last_error       TEXT,
  last_file_name   TEXT,
  last_file_id     TEXT
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
#variable_conflict use_column
DECLARE
  v_tables TEXT[] := ARRAY[
    'sa1010','sa3010','cc2010','za7010','sf2010','sc5010',
    'sb1010','sbm010','sd2010','sf4010','sx5010','sz1010'
  ];
  v_t TEXT;
  v_count BIGINT;
  v_log castor_ingest_log%ROWTYPE;
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  FOREACH v_t IN ARRAY v_tables LOOP
    BEGIN
      EXECUTE format('SELECT COUNT(*) FROM castor_src_%I', v_t) INTO v_count;
    EXCEPTION WHEN undefined_table THEN
      v_count := NULL;
    END;
    SELECT l.* INTO v_log
      FROM castor_ingest_log l
     WHERE l.table_name = v_t
     ORDER BY l.started_at DESC
     LIMIT 1;
    table_name       := v_t;
    rows_count       := v_count;
    last_ingest_at   := v_log.started_at;
    last_rows_in     := v_log.rows_in;
    last_rows_out    := v_log.rows_out;
    last_duration_ms := v_log.duration_ms;
    last_ok          := v_log.ok;
    last_error       := v_log.error;
    last_file_name   := v_log.file_name;
    last_file_id     := v_log.file_id;
    RETURN NEXT;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION castor_admin_sources_status() TO authenticated;

INSERT INTO castor_schema_migrations(version) VALUES ('037_products_items_time')
  ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- DOWN (reverter) — descomente para desfazer:
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS castor_client_status_history(UUID, TEXT, INT);
-- DROP FUNCTION IF EXISTS castor_crosssell(UUID, TEXT, INT);
-- DROP FUNCTION IF EXISTS castor_monthly_trend(UUID, TEXT, INT);
-- DROP FUNCTION IF EXISTS castor_top_groups(UUID, INT);
-- DROP FUNCTION IF EXISTS castor_top_products(UUID, INT, TEXT);
-- DROP FUNCTION IF EXISTS castor_product_mix(UUID, TEXT, INT);
-- DROP VIEW IF EXISTS castor_cliente_enriquecido;
-- DROP FUNCTION IF EXISTS castor_refresh_metrics_sd2();
-- DROP FUNCTION IF EXISTS castor_refresh_sa1010_derived();
-- DROP TABLE IF EXISTS castor_metrics_venda_cliente;
-- DROP TABLE IF EXISTS castor_metrics_mensal;
-- DROP TABLE IF EXISTS castor_metrics_grupo;
-- DROP TABLE IF EXISTS castor_metrics_produto;
-- DROP TABLE IF EXISTS castor_metrics_produto_cliente;
-- DROP FUNCTION IF EXISTS castor_cfop_class(TEXT);
-- DROP TABLE IF EXISTS castor_src_sz1010;
-- DROP TABLE IF EXISTS castor_src_sx5010;
-- DROP TABLE IF EXISTS castor_src_sf4010;
-- DROP TABLE IF EXISTS castor_src_sd2010;
-- DROP TABLE IF EXISTS castor_src_sbm010;
-- DROP TABLE IF EXISTS castor_src_sb1010;
-- DROP TABLE IF EXISTS castor_src_sa1010;
-- DELETE FROM castor_schema_migrations WHERE version = '037_products_items_time';
-- COMMIT;
-- NOTIFY pgrst, 'reload schema';
