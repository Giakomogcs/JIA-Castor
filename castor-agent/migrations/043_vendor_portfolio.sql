-- ============================================================
-- 043 — Carteira do vendedor (lista de empresas atribuídas)
-- ============================================================
-- Pedido do usuário:
--   * O CONSULTOR precisa de um botão na sidebar para ver a lista de
--     empresas que estão NA CARTEIRA DELE.
--   * O ADMIN precisa poder ver essa carteira PARA CADA UM dos vendedores
--     (escolhendo o vendedor).
--
-- "Carteira" = empresas atribuídas ao vendedor no Protheus, ou seja, todos
-- os clientes de castor_client_metrics_v2 cujo A1_VEND (a1_vend) é igual ao
-- código do vendedor (castor_vendor_user.codigo, resolvido via
-- castor_user_scope). Não confundir com "em fluxo/engajamento" (roteiro/
-- kanban) — aqui é a carteira CADASTRAL completa, trabalhada ou não.
--
-- Regras de acesso (SECURITY DEFINER, metadata-first):
--   * p_caller é obrigatório.
--   * p_target_user_id NULL  → o próprio caller vê a SUA carteira (vendedor).
--   * p_target_user_id != caller → exige admin (castor_assert_admin), e mostra
--     a carteira do vendedor-alvo. Admin também pode passar o próprio id.
--
-- Read-only. O front chama direto via supabaseClient.rpc — sem tocar n8n.
-- CREATE OR REPLACE — NUNCA DROP/CASCADE. Idempotente.
-- depends: 002 (auth), 004 (castor_vendor_user), 010 (castor_user_scope),
--          019 (castor_assert_admin), 039 (castor_client_metrics_v2)
-- reversible: DROP FUNCTION castor_vendor_portfolio(UUID,UUID,TEXT,INT)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION castor_vendor_portfolio(
  p_caller         UUID,
  p_target_user_id UUID DEFAULT NULL,
  p_q              TEXT DEFAULT NULL,
  p_limit          INT  DEFAULT 1000
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
BEGIN
  IF p_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'role','vendedor')
    INTO v_caller_role FROM auth.users u WHERE u.id = p_caller;
  IF v_caller_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'caller nao existe');
  END IF;

  -- Alvo: por padrão o próprio caller. Ver outro vendedor exige admin.
  v_target := COALESCE(p_target_user_id, p_caller);
  IF v_target <> p_caller THEN
    PERFORM castor_assert_admin(p_caller);
  END IF;

  -- Nome amigável do alvo (para o título do modal no front).
  SELECT COALESCE(u.raw_user_meta_data->>'full_name',
                  u.raw_user_meta_data->>'name',
                  u.email)
    INTO v_target_name FROM auth.users u WHERE u.id = v_target;

  -- Código de vendedor do alvo (A1_VEND/A3_COD via castor_vendor_user).
  SELECT s.vendor_code INTO v_vend FROM castor_user_scope(v_target) s;
  IF v_vend IS NOT NULL AND btrim(v_vend) = '' THEN v_vend := NULL; END IF;

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

GRANT EXECUTE ON FUNCTION castor_vendor_portfolio(UUID, UUID, TEXT, INT)
  TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('043_vendor_portfolio') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
