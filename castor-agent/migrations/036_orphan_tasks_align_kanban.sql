-- file: 036_orphan_tasks_align_kanban.sql
-- tier: A
-- purpose:
--   A 035 manteve `negativo` na lista de outcomes "abertos" da pseudo-rota
--   de tarefas avulsas. Mas o classify() do kanban (front) NÃO tem coluna
--   para `negativo` — ele intencionalmente retorna null pra esse outcome
--   ("recusou desta vez, mas voltará no futuro").
--
--   Resultado visível: o widget "Progresso por dia" no sidebar mostrava
--   "1 roteiro · 2 paradas" mas só 1 card aparecia no kanban (o card com
--   outcome=negativo era contabilizado em stops_count e ficava invisível).
--
-- Fix:
--   Remove 'negativo' da lista de "tarefas em aberto" das pseudo-rotas
--   órfãs (vendor + admin). Cliente com outcome=negativo cai em "limbo"
--   até a próxima rodada de sugestões IA — exatamente como o kanban
--   já trata.
--
-- depends: 035 (orphan_tasks_terminal_fix)
-- reversible: yes (re-aplique 035)
-- IDEMPOTENTE.

BEGIN;

CREATE OR REPLACE FUNCTION castor_vendor_orphan_tasks(p_caller UUID)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_routes    JSONB := '[]'::jsonb;
  v_details   JSONB := '{}'::jsonb;
  v_stops     JSONB;
  v_count     INT;
  v_owner     JSONB;
  v_pseudo_id TEXT;
  v_user_name TEXT;
  v_email     TEXT;
BEGIN
  IF p_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'full_name',
                  u.raw_user_meta_data->>'name',
                  u.email),
         u.email
    INTO v_user_name, v_email
    FROM auth.users u
   WHERE u.id = p_caller;

  SELECT COALESCE(jsonb_agg(stop_obj ORDER BY stop_obj->>'next_contact_at' NULLS LAST), '[]'::jsonb),
         COUNT(*)::INT
    INTO v_stops, v_count
    FROM (
      SELECT jsonb_build_object(
               'cliente_codigo',  t.cliente_codigo,
               'name',            COALESCE(t.cliente_nome, t.cliente_codigo),
               'mun',             t.municipio,
               'uf',              t.uf,
               'a1_mun',          t.municipio,
               'a1_est',          t.uf,
               'outcome',         t.outcome,
               'interaction_type', t.interaction_type,
               'notes',           t.notes,
               'next_contact_at',
                 CASE WHEN t.next_contact_at IS NOT NULL
                      THEN to_char(t.next_contact_at, 'YYYY-MM-DD')
                      ELSE NULL END,
               'next_action',     t.next_action,
               'visited_at',      t.occurred_at,
               '_orphan_task',    true,
               '_interaction_id', t.id
             ) AS stop_obj
        FROM (
          SELECT DISTINCT ON (i2.cliente_codigo)
                 i2.id, i2.cliente_codigo, i2.outcome, i2.interaction_type,
                 i2.notes, i2.next_contact_at, i2.next_action, i2.occurred_at,
                 m.a1_nome AS cliente_nome,
                 m.a1_mun  AS municipio,
                 m.a1_est  AS uf
            FROM castor_client_interactions i2
            LEFT JOIN castor_client_metrics_v2 m ON m.cliente_codigo = i2.cliente_codigo
           WHERE i2.vendedor_user_id = p_caller
             AND i2.route_id IS NULL
           ORDER BY i2.cliente_codigo, i2.occurred_at DESC
        ) t
        -- Aberto = sem outcome OU outcomes que TÊM coluna no kanban.
        -- Excluímos 'negativo' propositalmente (cai em limbo até a IA
        -- re-sugerir). Excluímos terminais (convertido / nao_existe_mais
        -- / nao_interessado_permanente).
       WHERE t.outcome IS NULL
          OR t.outcome IN ('voltar_depois','aguardando_resposta','pedido_em_negociacao','sem_contato')
    ) sub;

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'data', jsonb_build_object('routes', '[]'::jsonb, 'details', '{}'::jsonb)
    );
  END IF;

  v_pseudo_id := 'orphan:' || p_caller::text;
  v_owner := jsonb_build_object(
    'id',        p_caller,
    'email',     v_email,
    'full_name', v_user_name
  );

  v_routes := jsonb_build_array(jsonb_build_object(
    'id',           v_pseudo_id,
    'name',         '📋 Tarefas avulsas',
    'source',       'vendor_orphan_tasks',
    'status',       'planejado',
    'total_km',     0,
    'stops_count',  v_count,
    'done_count',   0,
    'ai_rationale', NULL,
    'maps_url',     NULL,
    'created_at',   NOW(),
    'updated_at',   NOW(),
    'completed_at', NULL,
    'user_id',      p_caller,
    'user_name',    v_user_name,
    '_orphan',      true
  ));

  v_details := jsonb_build_object(v_pseudo_id, jsonb_build_object(
    'id',          v_pseudo_id,
    'name',        '📋 Tarefas avulsas',
    'status',      'planejado',
    'user_id',     p_caller,
    'owner',       v_owner,
    'stops',       v_stops,
    'stops_count', v_count,
    'done_count',  0,
    '_orphan',     true
  ));

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object('routes', v_routes, 'details', v_details)
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_vendor_orphan_tasks(UUID) TO authenticated, service_role;

-- Espelha em admin_orphan_tasks
CREATE OR REPLACE FUNCTION castor_admin_orphan_tasks(p_caller UUID)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_routes  JSONB := '[]'::jsonb;
  v_details JSONB := '{}'::jsonb;
  v_vendor  RECORD;
  v_stops   JSONB;
  v_count   INT;
  v_owner   JSONB;
  v_pseudo_id TEXT;
BEGIN
  PERFORM castor_assert_admin(p_caller);

  FOR v_vendor IN
    SELECT i.vendedor_user_id AS uid,
           COALESCE(u.raw_user_meta_data->>'full_name',
                    u.raw_user_meta_data->>'name',
                    u.email) AS user_name,
           u.email AS email
      FROM castor_client_interactions i
      LEFT JOIN auth.users u ON u.id = i.vendedor_user_id
     WHERE i.route_id IS NULL
       AND i.vendedor_user_id IS NOT NULL
       AND COALESCE(u.raw_user_meta_data->>'role','vendedor') <> 'admin'
     GROUP BY i.vendedor_user_id, u.email, u.raw_user_meta_data
  LOOP
    SELECT COALESCE(jsonb_agg(stop_obj ORDER BY stop_obj->>'next_contact_at' NULLS LAST), '[]'::jsonb),
           COUNT(*)::INT
      INTO v_stops, v_count
      FROM (
        SELECT jsonb_build_object(
                 'cliente_codigo', t.cliente_codigo,
                 'name',           COALESCE(t.cliente_nome, t.cliente_codigo),
                 'mun',            t.municipio,
                 'uf',             t.uf,
                 'a1_mun',         t.municipio,
                 'a1_est',         t.uf,
                 'outcome',        t.outcome,
                 'interaction_type', t.interaction_type,
                 'notes',          t.notes,
                 'next_contact_at',
                   CASE WHEN t.next_contact_at IS NOT NULL
                        THEN to_char(t.next_contact_at,'YYYY-MM-DD')
                        ELSE NULL END,
                 'next_action',    t.next_action,
                 'visited_at',     t.occurred_at,
                 '_orphan_task',   true,
                 '_interaction_id', t.id
               ) AS stop_obj
          FROM (
            SELECT DISTINCT ON (i2.cliente_codigo)
                   i2.id, i2.cliente_codigo, i2.outcome, i2.interaction_type,
                   i2.notes, i2.next_contact_at, i2.next_action, i2.occurred_at,
                   m.a1_nome AS cliente_nome,
                   m.a1_mun  AS municipio,
                   m.a1_est  AS uf
              FROM castor_client_interactions i2
              LEFT JOIN castor_client_metrics_v2 m ON m.cliente_codigo = i2.cliente_codigo
             WHERE i2.vendedor_user_id = v_vendor.uid
               AND i2.route_id IS NULL
             ORDER BY i2.cliente_codigo, i2.occurred_at DESC
          ) t
         WHERE t.outcome IS NULL
            OR t.outcome IN ('voltar_depois','aguardando_resposta','pedido_em_negociacao','sem_contato')
      ) sub;

    IF v_count = 0 THEN CONTINUE; END IF;

    v_pseudo_id := 'orphan:' || v_vendor.uid::text;
    v_owner := jsonb_build_object(
      'id', v_vendor.uid,
      'email', v_vendor.email,
      'full_name', v_vendor.user_name
    );

    v_routes := v_routes || jsonb_build_array(jsonb_build_object(
      'id',           v_pseudo_id,
      'name',         '📋 Tarefas avulsas — ' || COALESCE(v_vendor.user_name, v_vendor.email, v_vendor.uid::text),
      'source',       'admin_orphan_tasks',
      'status',       'planejado',
      'total_km',     0,
      'stops_count',  v_count,
      'done_count',   0,
      'ai_rationale', NULL,
      'maps_url',     NULL,
      'created_at',   NOW(),
      'updated_at',   NOW(),
      'completed_at', NULL,
      'user_id',      v_vendor.uid,
      'user_name',    v_vendor.user_name,
      '_orphan',      true
    ));

    v_details := v_details || jsonb_build_object(v_pseudo_id, jsonb_build_object(
      'id',          v_pseudo_id,
      'name',        '📋 Tarefas avulsas — ' || COALESCE(v_vendor.user_name, v_vendor.email, v_vendor.uid::text),
      'status',      'planejado',
      'user_id',     v_vendor.uid,
      'owner',       v_owner,
      'stops',       v_stops,
      'stops_count', v_count,
      'done_count',  0,
      '_orphan',     true
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'routes',  v_routes,
      'details', v_details
    )
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_admin_orphan_tasks(UUID) TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('036_orphan_tasks_align_kanban') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
