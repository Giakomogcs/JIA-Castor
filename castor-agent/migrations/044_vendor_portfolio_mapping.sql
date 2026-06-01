-- ============================================================
-- 044 — Carteira: mapeamento vendedor↔Protheus + diretório + override admin
-- ============================================================
-- Problema relatado:
--   * O CONSULTOR não vê as empresas (nem o status) da sua carteira.
--   * O ADMIN também não vê a carteira de nenhum vendedor.
--
-- Causa-raiz:
--   castor_vendor_portfolio (043) filtra por `m.a1_vend = vendor_code`, e o
--   vendor_code vem de castor_vendor_user (via castor_user_scope). Como NÃO há
--   nenhuma UI para vincular um usuário do app ao código A3 do Protheus, a
--   tabela castor_vendor_user fica vazia → vendor_code é sempre NULL → a
--   carteira volta vazia ("sem código Protheus vinculado") para TODOS.
--
-- Correções desta migration (todas aditivas / idempotentes, sem DROP CASCADE):
--   1. castor_admin_list_users agora também devolve `vendor_code` (LEFT JOIN
--      castor_vendor_user) → o editor de usuário pré-preenche o vínculo.
--   2. Nova RPC castor_vendor_directory(p_q): lista os vendedores REAIS do
--      Protheus (a1_vend distinto em castor_client_metrics_v2 + nome via
--      SA3010 + contagem de clientes) para popular o seletor (editor + modal
--      da carteira). Admin-only.
--   3. castor_vendor_portfolio ganha o parâmetro opcional `p_vendor_code`:
--      admin pode abrir a carteira de QUALQUER código Protheus diretamente,
--      sem depender do vínculo castor_vendor_user. O caminho do vendedor
--      (self) continua usando o vínculo.
--
-- depends: 002 (auth/list_users/is_admin), 004 (castor_vendor_user/set_vendor_code),
--          010 (castor_user_scope), 019 (castor_assert_admin),
--          039 (castor_client_metrics_v2), 043 (castor_vendor_portfolio)
-- reversible: ver bloco no fim (comentado).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) castor_admin_list_users + vendor_code
--    (muda o RETURNS TABLE → precisa DROP antes de recriar)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS castor_admin_list_users();
CREATE OR REPLACE FUNCTION castor_admin_list_users()
RETURNS TABLE(
  user_id     UUID,
  email       TEXT,
  full_name   TEXT,
  role        TEXT,
  estados     JSONB,
  cidades     JSONB,
  vendor_code TEXT,
  created_at  TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = auth, public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      u.id,
      u.email::TEXT,
      COALESCE(u.raw_user_meta_data->>'full_name','')::TEXT,
      COALESCE(u.raw_user_meta_data->>'role','vendedor')::TEXT,
      COALESCE(u.raw_user_meta_data->'estados', '[]'::jsonb),
      COALESCE(u.raw_user_meta_data->'cidades', '[]'::jsonb),
      (SELECT vu.codigo FROM castor_vendor_user vu WHERE vu.user_id = u.id),
      u.created_at
    FROM auth.users u
    WHERE COALESCE(u.raw_user_meta_data->>'company_name','') = 'castor'
    ORDER BY u.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_admin_list_users() TO authenticated;

-- ------------------------------------------------------------
-- 2) castor_vendor_directory — vendedores reais do Protheus
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION castor_vendor_directory(p_q TEXT DEFAULT NULL)
RETURNS TABLE(
  a3_cod         TEXT,
  a3_nome        TEXT,
  a3_nreduz      TEXT,
  total_clientes INT
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_q TEXT := NULLIF(btrim(COALESCE(p_q, '')), '');
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      m.a1_vend::TEXT                              AS a3_cod,
      COALESCE(MAX(v.a3_nome), '')::TEXT           AS a3_nome,
      COALESCE(MAX(v.a3_nreduz), '')::TEXT         AS a3_nreduz,
      COUNT(*)::INT                                AS total_clientes
    FROM castor_client_metrics_v2 m
    LEFT JOIN castor_src_sa3010 v ON v.a3_cod = m.a1_vend
    WHERE m.a1_vend IS NOT NULL
      AND btrim(m.a1_vend) <> ''
      AND COALESCE(m.lifecycle_status, '') NOT IN ('encerrado','nao_interessado_permanente')
      AND (
        v_q IS NULL
        OR m.a1_vend ILIKE '%' || v_q || '%'
        OR COALESCE(v.a3_nome, '')   ILIKE '%' || v_q || '%'
        OR COALESCE(v.a3_nreduz, '') ILIKE '%' || v_q || '%'
      )
    GROUP BY m.a1_vend
    ORDER BY COUNT(*) DESC, m.a1_vend;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_vendor_directory(TEXT) TO authenticated, service_role;

-- ------------------------------------------------------------
-- 3) castor_vendor_portfolio + p_vendor_code (override admin)
--    Adiciona 5º parâmetro → recria a função (DROP da assinatura 043).
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS castor_vendor_portfolio(UUID, UUID, TEXT, INT);
CREATE OR REPLACE FUNCTION castor_vendor_portfolio(
  p_caller         UUID,
  p_target_user_id UUID DEFAULT NULL,
  p_q              TEXT DEFAULT NULL,
  p_limit          INT  DEFAULT 1000,
  p_vendor_code    TEXT DEFAULT NULL
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_caller_role TEXT;
  v_target      UUID;
  v_vend        TEXT;
  v_target_name TEXT;
  v_rows        JSONB;
  v_total       INT  := 0;
  v_lim         INT;
  v_q           TEXT;
  v_sum_fat     NUMERIC := 0;
  v_n_ativos    INT := 0;
  v_n_reativar  INT := 0;
  v_n_sem_hist  INT := 0;
  v_vend_in     TEXT := NULLIF(btrim(COALESCE(p_vendor_code, '')), '');
BEGIN
  IF p_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'role','vendedor')
    INTO v_caller_role FROM auth.users u WHERE u.id = p_caller;
  IF v_caller_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'caller nao existe');
  END IF;

  IF v_vend_in IS NOT NULL THEN
    -- Override admin: abre a carteira de um código Protheus arbitrário,
    -- independente de vínculo castor_vendor_user.
    PERFORM castor_assert_admin(p_caller);
    v_vend   := v_vend_in;
    v_target := NULL;
    SELECT a3_nome INTO v_target_name
      FROM castor_src_sa3010 WHERE a3_cod = v_vend LIMIT 1;
    IF v_target_name IS NULL OR btrim(v_target_name) = '' THEN
      v_target_name := 'Vendedor ' || v_vend;
    END IF;
  ELSE
    -- Alvo: por padrão o próprio caller. Ver outro vendedor exige admin.
    v_target := COALESCE(p_target_user_id, p_caller);
    IF v_target <> p_caller THEN
      PERFORM castor_assert_admin(p_caller);
    END IF;

    SELECT COALESCE(u.raw_user_meta_data->>'full_name',
                    u.raw_user_meta_data->>'name',
                    u.email)
      INTO v_target_name FROM auth.users u WHERE u.id = v_target;

    -- Código de vendedor do alvo (A1_VEND/A3_COD via castor_vendor_user).
    SELECT s.vendor_code INTO v_vend FROM castor_user_scope(v_target) s;
    IF v_vend IS NOT NULL AND btrim(v_vend) = '' THEN v_vend := NULL; END IF;
  END IF;

  -- Sem código mapeado → carteira vazia (vendedor ainda não vinculado ao A3).
  IF v_vend IS NULL THEN
    RETURN jsonb_build_object(
      'ok',             true,
      'target_user_id', v_target,
      'target_name',    v_target_name,
      'vendor_code',    NULL,
      'total',          0,
      'clients',        '[]'::jsonb,
      'summary',        jsonb_build_object(
                          'faturamento_total', 0,
                          'ativos', 0, 'reativar', 0, 'sem_historico', 0
                        ),
      'note',           'Vendedor sem codigo Protheus vinculado'
    );
  END IF;

  v_lim := GREATEST(1, LEAST(COALESCE(p_limit, 1000), 5000));
  v_q   := NULLIF(btrim(COALESCE(p_q, '')), '');

  SELECT
    jsonb_agg(row_obj ORDER BY fat DESC NULLS LAST, last_ord DESC NULLS LAST),
    COUNT(*)::int,
    COALESCE(SUM(fat), 0),
    COUNT(*) FILTER (WHERE status_real = 'ATIVO'),
    COUNT(*) FILTER (WHERE COALESCE(elegivel_reativacao, FALSE)
                       OR status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')),
    COUNT(*) FILTER (WHERE status_real = 'SEM_HISTORICO' OR pedidos = 0)
    INTO v_rows, v_total, v_sum_fat, v_n_ativos, v_n_reativar, v_n_sem_hist
  FROM (
    SELECT
      m.faturamento_alltime AS fat,
      m.ultimo_pedido       AS last_ord,
      m.status_real,
      m.elegivel_reativacao,
      COALESCE(m.pedidos_alltime, 0) AS pedidos,
      jsonb_build_object(
        'cliente_codigo',      m.cliente_codigo,
        'a1_nome',             m.a1_nome,
        'a1_vend',             m.a1_vend,
        'vendedor_nome',       m.vendedor_nome,
        'a1_end',              m.a1_end,
        'a1_mun',              m.a1_mun,
        'a1_est',              m.a1_est,
        'contato_nome',        m.contato_nome,
        'contato_tel',         m.contato_tel,
        'contato_whats',       m.contato_whats,
        'contato_email',       m.contato_email,
        'status_real',         m.status_real,
        'status_cadastral',    m.status_cadastral,
        'elegivel_reativacao', m.elegivel_reativacao,
        'porte_efetivo',       m.porte_efetivo,
        'faturamento_alltime', m.faturamento_alltime,
        'pedidos_alltime',     COALESCE(m.pedidos_alltime, 0),
        'ultimo_pedido',       m.ultimo_pedido,
        'dias_sem_pedido',     m.dias_sem_pedido
      ) AS row_obj
    FROM castor_client_metrics_v2 m
    WHERE m.a1_vend = v_vend
      AND COALESCE(m.lifecycle_status, '') NOT IN ('encerrado','nao_interessado_permanente')
      AND (
        v_q IS NULL
        OR m.a1_nome ILIKE '%' || v_q || '%'
        OR m.cliente_codigo ILIKE '%' || v_q || '%'
        OR COALESCE(m.a1_mun, '') ILIKE '%' || v_q || '%'
      )
    LIMIT v_lim
  ) sub;

  RETURN jsonb_build_object(
    'ok',             true,
    'target_user_id', v_target,
    'target_name',    v_target_name,
    'vendor_code',    v_vend,
    'total',          COALESCE(v_total, 0),
    'clients',        COALESCE(v_rows, '[]'::jsonb),
    'summary',        jsonb_build_object(
                        'faturamento_total', v_sum_fat,
                        'ativos',            v_n_ativos,
                        'reativar',          v_n_reativar,
                        'sem_historico',     v_n_sem_hist
                      )
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_vendor_portfolio(UUID, UUID, TEXT, INT, TEXT)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('044_vendor_portfolio_mapping') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- reversible (manual):
--   DROP FUNCTION IF EXISTS castor_vendor_directory(TEXT);
--   DROP FUNCTION IF EXISTS castor_vendor_portfolio(UUID,UUID,TEXT,INT,TEXT);
--   -- e recriar 043_vendor_portfolio.sql + a versão 002 de castor_admin_list_users.
-- ============================================================
