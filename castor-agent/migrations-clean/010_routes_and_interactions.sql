-- file: 010_routes_and_interactions.sql
-- tier: A
-- purpose: Tabela castor_route_saved (1 rota aberta por usuário) e TODAS as funções de roteiro/cliente:
--   route_save, route_save_unified, route_build_maps_url, route_list, route_detail, route_metrics,
--   route_update_stop, route_candidates, route_stop_remove, route_delete (2 overloads),
--   client_detail, client_address_override_set/get, client_status_set,
--   client_interaction_add/list, client_pending_followups, client_recent_changes,
--   admin_route_reassign.
-- depends: 001, 005, 006, 007, 008
-- IDEMPOTENTE.

BEGIN;

CREATE TABLE IF NOT EXISTS castor_route_saved (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID,
  name            TEXT NOT NULL,
  source          TEXT NOT NULL CHECK (source IN ('ai_auto','manual','mixed','reactivation','prospect')),
  status          TEXT NOT NULL DEFAULT 'planejado' CHECK (status IN ('planejado','em_andamento','concluido','cancelado')),
  stops           JSONB NOT NULL,
  total_km        NUMERIC(10,2),
  origin_lat      DOUBLE PRECISION,
  origin_lng      DOUBLE PRECISION,
  ai_rationale    TEXT,
  maps_url        TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS castor_route_saved_user_idx    ON castor_route_saved(user_id);
CREATE INDEX IF NOT EXISTS castor_route_saved_status_idx  ON castor_route_saved(status);
CREATE INDEX IF NOT EXISTS castor_route_saved_created_idx ON castor_route_saved(created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS castor_route_saved_one_open_per_user_uq
  ON castor_route_saved(user_id)
  WHERE status IN ('planejado','em_andamento');

CREATE OR REPLACE FUNCTION castor_route_saved_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS castor_route_saved_touch_trg ON castor_route_saved;
CREATE TRIGGER castor_route_saved_touch_trg BEFORE UPDATE ON castor_route_saved
FOR EACH ROW EXECUTE FUNCTION castor_route_saved_touch();

-- ----------------------------------------------------------------------------
-- save / save_unified  (route_save é wrapper de route_save_unified)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION castor_route_save(
  p_user_id      UUID,
  p_name         TEXT,
  p_source       TEXT,
  p_stops        JSONB,
  p_total_km     NUMERIC,
  p_origin_lat   DOUBLE PRECISION,
  p_origin_lng   DOUBLE PRECISION,
  p_ai_rationale TEXT,
  p_maps_url     TEXT
) RETURNS UUID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := castor_route_save_unified(
    p_user_id, p_name, p_source, p_stops, p_total_km,
    p_origin_lat, p_origin_lng, p_ai_rationale, p_maps_url
  );
  RETURN (v_res->>'route_id')::UUID;
END; $$;

CREATE OR REPLACE FUNCTION castor_route_save_unified(
  p_user_id      UUID,
  p_name         TEXT,
  p_source       TEXT,
  p_stops        JSONB,
  p_total_km     NUMERIC,
  p_origin_lat   DOUBLE PRECISION,
  p_origin_lng   DOUBLE PRECISION,
  p_ai_rationale TEXT,
  p_maps_url     TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_existing castor_route_saved%ROWTYPE;
  v_id       UUID;
  v_merged   JSONB;
  v_known    TEXT[];
  v_max_seq  INT := 0;
  v_elem     JSONB;
  v_origin_lat DOUBLE PRECISION;
  v_origin_lng DOUBLE PRECISION;
  v_total_km NUMERIC;
  v_count_new INT := 0;
  v_role     TEXT;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'user_id obrigatorio'; END IF;
  IF p_stops IS NULL OR jsonb_array_length(p_stops) = 0 THEN
    RAISE EXCEPTION 'stops vazio';
  END IF;

  SELECT COALESCE(raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users WHERE id = p_user_id;
  IF v_role = 'admin' THEN
    RAISE EXCEPTION 'admin_nao_pode_ter_roteiro: use castor_admin_task_assign / castor_admin_card_reassign'
      USING ERRCODE='42501';
  END IF;
  IF v_role = 'inactive' THEN
    RAISE EXCEPTION 'usuario_inativo' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_existing
    FROM castor_route_saved
   WHERE user_id = p_user_id
     AND status IN ('planejado','em_andamento')
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_existing.id IS NULL THEN
    INSERT INTO castor_route_saved(
      user_id, name, source, stops, total_km,
      origin_lat, origin_lng, ai_rationale, maps_url
    )
    VALUES (
      p_user_id,
      COALESCE(NULLIF(btrim(p_name),''), 'Roteiro do dia '||to_char(NOW(),'DD/MM')),
      COALESCE(p_source,'manual'),
      COALESCE(p_stops,'[]'::jsonb),
      p_total_km,
      p_origin_lat, p_origin_lng, p_ai_rationale, p_maps_url
    )
    RETURNING id INTO v_id;
    RETURN jsonb_build_object(
      'route_id', v_id,
      'appended', FALSE,
      'added_count', jsonb_array_length(COALESCE(p_stops,'[]'::jsonb))
    );
  END IF;

  SELECT COALESCE(array_agg(s->>'cliente_codigo'), ARRAY[]::TEXT[])
    INTO v_known
    FROM jsonb_array_elements(COALESCE(v_existing.stops,'[]'::jsonb)) s;

  SELECT COALESCE(MAX((s->>'seq')::INT), 0)
    INTO v_max_seq
    FROM jsonb_array_elements(COALESCE(v_existing.stops,'[]'::jsonb)) s;

  v_merged := COALESCE(v_existing.stops,'[]'::jsonb);

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_stops) LOOP
    IF (v_elem->>'cliente_codigo') IS NULL THEN CONTINUE; END IF;
    IF (v_elem->>'cliente_codigo') = ANY(v_known) THEN CONTINUE; END IF;
    v_max_seq := v_max_seq + 1;
    v_count_new := v_count_new + 1;
    v_merged := v_merged || jsonb_build_array(
      jsonb_set(v_elem, '{seq}', to_jsonb(v_max_seq), TRUE)
    );
    v_known := array_append(v_known, v_elem->>'cliente_codigo');
  END LOOP;

  v_origin_lat := COALESCE(v_existing.origin_lat, p_origin_lat);
  v_origin_lng := COALESCE(v_existing.origin_lng, p_origin_lng);
  v_total_km   := COALESCE(v_existing.total_km,0) + COALESCE(p_total_km,0);

  UPDATE castor_route_saved
     SET stops      = v_merged,
         total_km   = v_total_km,
         origin_lat = v_origin_lat,
         origin_lng = v_origin_lng,
         maps_url   = castor_route_build_maps_url(v_origin_lat, v_origin_lng, v_merged),
         ai_rationale = CASE
            WHEN p_ai_rationale IS NULL OR btrim(p_ai_rationale) = '' THEN v_existing.ai_rationale
            WHEN v_existing.ai_rationale IS NULL THEN p_ai_rationale
            ELSE v_existing.ai_rationale || E'\n---\n' || p_ai_rationale
         END,
         source     = CASE
            WHEN v_existing.source = COALESCE(p_source,'manual') THEN v_existing.source
            ELSE 'mixed'
         END,
         status     = CASE WHEN v_existing.status = 'concluido' THEN 'planejado' ELSE v_existing.status END,
         updated_at = NOW()
   WHERE id = v_existing.id;

  RETURN jsonb_build_object(
    'route_id', v_existing.id,
    'appended', TRUE,
    'added_count', v_count_new,
    'total_stops', jsonb_array_length(v_merged)
  );
END; $$;

-- ----------------------------------------------------------------------------
-- build_maps_url
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION castor_route_build_maps_url(
  p_origin_lat DOUBLE PRECISION,
  p_origin_lng DOUBLE PRECISION,
  p_stops      JSONB
) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_url   TEXT;
  v_pts   TEXT := '';
  v_count INT := 0;
  v_elem  JSONB;
  v_lat   DOUBLE PRECISION;
  v_lng   DOUBLE PRECISION;
  v_addr  TEXT;
  v_token TEXT;
BEGIN
  IF p_origin_lat IS NULL OR p_origin_lng IS NULL OR p_stops IS NULL OR jsonb_array_length(p_stops) = 0 THEN
    RETURN NULL;
  END IF;
  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_stops) LOOP
    v_lat := NULLIF(v_elem->>'lat','')::DOUBLE PRECISION;
    v_lng := NULLIF(v_elem->>'lng','')::DOUBLE PRECISION;
    v_token := NULL;

    IF v_lat IS NOT NULL AND v_lng IS NOT NULL THEN
      v_token := v_lat::TEXT || ',' || v_lng::TEXT;
    ELSE
      v_addr := NULLIF(btrim(COALESCE(v_elem->>'address','')),'');
      IF v_addr IS NULL THEN
        v_addr := btrim(
          COALESCE(v_elem->>'a1_end','') ||
          CASE WHEN COALESCE(v_elem->>'a1_mun','') <> '' THEN ', ' || (v_elem->>'a1_mun') ELSE '' END ||
          CASE WHEN COALESCE(v_elem->>'a1_est','') <> '' THEN ' - ' || (v_elem->>'a1_est') ELSE '' END
        );
        v_addr := NULLIF(v_addr,'');
      END IF;
      IF v_addr IS NULL THEN CONTINUE; END IF;
      v_token := replace(replace(replace(replace(replace(replace(
                 v_addr,
                 '%','%25'),
                 ' ','%20'),
                 ',','%2C'),
                 '/','%2F'),
                 '#','%23'),
                 '?','%3F');
    END IF;

    v_count := v_count + 1;
    IF v_count > 23 THEN EXIT; END IF;
    v_pts := v_pts || '/' || v_token;
  END LOOP;
  IF v_count = 0 THEN RETURN NULL; END IF;
  v_url := 'https://www.google.com/maps/dir/' ||
           p_origin_lat::TEXT || ',' || p_origin_lng::TEXT ||
           v_pts ||
           '/' || p_origin_lat::TEXT || ',' || p_origin_lng::TEXT;
  RETURN v_url;
END; $$;

-- ----------------------------------------------------------------------------
-- list / detail / metrics
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION castor_route_list(
  p_user_id    UUID,
  p_only_open  BOOLEAN DEFAULT FALSE,
  p_limit      INT     DEFAULT 50
)
RETURNS TABLE(
  id UUID, name TEXT, source TEXT, status TEXT,
  total_km NUMERIC, stops_count INT, done_count INT,
  ai_rationale TEXT, maps_url TEXT,
  created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, completed_at TIMESTAMPTZ,
  user_id UUID, user_name TEXT
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_is_admin BOOLEAN;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  RETURN QUERY
  SELECT r.id, r.name, r.source, r.status,
         r.total_km,
         COALESCE(jsonb_array_length(r.stops),0)::INT AS stops_count,
         (SELECT COUNT(*)::INT FROM jsonb_array_elements(r.stops) s
            WHERE (s->>'outcome') IS NOT NULL) AS done_count,
         r.ai_rationale, r.maps_url,
         r.created_at, r.updated_at, r.completed_at,
         r.user_id,
         COALESCE(
           u.raw_user_meta_data->>'full_name',
           u.raw_user_meta_data->>'name',
           u.email,
           NULL
         ) AS user_name
    FROM castor_route_saved r
    LEFT JOIN auth.users u ON u.id = r.user_id
   WHERE (v_is_admin OR r.user_id = p_user_id)
     AND (NOT p_only_open OR r.status IN ('planejado','em_andamento'))
   ORDER BY r.created_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
END; $$;

CREATE OR REPLACE FUNCTION castor_route_detail(
  p_user_id  UUID,
  p_route_id UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_is_admin     BOOLEAN;
  v_row          castor_route_saved%ROWTYPE;
  v_owner        JSONB;
  v_stops_out    JSONB := '[]'::jsonb;
  v_stop         JSONB;
  v_codigo       TEXT;
  v_done_count   INT := 0;

  v_outcome      TEXT;
  v_itype        TEXT;
  v_notes        TEXT;
  v_next_at      DATE;
  v_next_action  TEXT;
  v_occurred_at  TIMESTAMPTZ;

  v_stop_visited TIMESTAMPTZ;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'route_not_found');
  END IF;

  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT to_jsonb(u.*) INTO v_owner
    FROM (SELECT id, email, raw_user_meta_data->>'full_name' AS full_name
            FROM auth.users WHERE id = v_row.user_id) u;

  FOR v_stop IN SELECT * FROM jsonb_array_elements(COALESCE(v_row.stops, '[]'::jsonb)) LOOP
    v_codigo := v_stop->>'cliente_codigo';

    SELECT outcome, interaction_type, notes, next_contact_at, next_action, occurred_at
      INTO v_outcome, v_itype, v_notes, v_next_at, v_next_action, v_occurred_at
      FROM (
        SELECT i.outcome, i.interaction_type, i.notes,
               i.next_contact_at, i.next_action, i.occurred_at
          FROM castor_client_interactions i
         WHERE i.cliente_codigo = v_codigo
           AND i.vendedor_user_id = v_row.user_id
        UNION ALL
        SELECT f.outcome,
               'visita_presencial'::TEXT      AS interaction_type,
               f.notes,
               f.next_contact_at,
               NULL::TEXT                     AS next_action,
               f.visited_at                   AS occurred_at
          FROM castor_visita_feedback f
         WHERE f.cliente_codigo = v_codigo
           AND f.vendedor_user_id = v_row.user_id
      ) src
     WHERE COALESCE(outcome,'') <> ''
     ORDER BY occurred_at DESC NULLS LAST
     LIMIT 1;

    IF v_outcome IS NOT NULL AND v_outcome <> '' THEN
      v_stop_visited := NULLIF(v_stop->>'visited_at','')::TIMESTAMPTZ;
      IF v_stop_visited IS NULL OR v_occurred_at >= v_stop_visited THEN
        v_stop := v_stop
          || jsonb_build_object(
               'outcome',          v_outcome,
               'interaction_type', v_itype,
               'visited_at',       v_occurred_at
             )
          || jsonb_build_object(
               'next_contact_at',
               CASE WHEN v_next_at IS NOT NULL
                    THEN to_char(v_next_at,'YYYY-MM-DD')
                    ELSE NULL END
             )
          || (CASE WHEN v_notes IS NOT NULL AND btrim(v_notes) <> ''
                    THEN jsonb_build_object('notes', v_notes)
                    ELSE '{}'::jsonb END)
          || (CASE WHEN v_next_action IS NOT NULL AND btrim(v_next_action) <> ''
                    THEN jsonb_build_object('next_action', v_next_action)
                    ELSE '{}'::jsonb END);
      END IF;
    END IF;

    v_stops_out := v_stops_out || jsonb_build_array(v_stop);

    IF (v_stop->>'outcome') IN ('visitou','convertido','nao_existe_mais','nao_interessado_permanente') THEN
      v_done_count := v_done_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'route', jsonb_build_object(
      'id', v_row.id,
      'name', v_row.name,
      'source', v_row.source,
      'status', v_row.status,
      'total_km', v_row.total_km,
      'origin_lat', v_row.origin_lat,
      'origin_lng', v_row.origin_lng,
      'ai_rationale', v_row.ai_rationale,
      'maps_url', v_row.maps_url,
      'stops', v_stops_out,
      'stops_count', COALESCE(jsonb_array_length(v_stops_out), 0),
      'done_count', v_done_count,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at,
      'completed_at', v_row.completed_at,
      'user_id', v_row.user_id,
      'owner', v_owner
    )
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_route_metrics(
  p_user_id    UUID,
  p_days       INT DEFAULT 30
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_result   JSONB;
BEGIN
  SELECT COALESCE(u.raw_user_meta_data->>'role','vendedor') = 'admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  WITH base AS (
    SELECT r.*
      FROM castor_route_saved r
     WHERE r.created_at >= NOW() - (COALESCE(p_days, 30) || ' days')::interval
       AND (v_is_admin OR r.user_id = p_user_id)
  ),
  stops_flat AS (
    SELECT b.id, b.user_id, b.status,
           jsonb_array_elements(b.stops) AS stop
      FROM base b
  ),
  per_user AS (
    SELECT b.user_id,
           (SELECT u.raw_user_meta_data->>'full_name' FROM auth.users u WHERE u.id = b.user_id) AS user_name,
           COUNT(*)                                      AS routes,
           SUM(b.total_km)                               AS km,
           SUM(jsonb_array_length(b.stops))              AS stops_total,
           SUM(CASE WHEN b.status = 'concluido' THEN 1 ELSE 0 END) AS concluidos
      FROM base b
     GROUP BY b.user_id
  ),
  outcomes AS (
    SELECT (stop->>'outcome')::text AS outcome, COUNT(*) AS qt
      FROM stops_flat
     WHERE stop ? 'outcome'
     GROUP BY 1
  )
  SELECT jsonb_build_object(
    'total_routes',     (SELECT COUNT(*) FROM base),
    'total_km',         (SELECT COALESCE(SUM(total_km),0) FROM base),
    'total_stops',      (SELECT COALESCE(SUM(jsonb_array_length(stops)),0) FROM base),
    'by_status',        (SELECT COALESCE(jsonb_object_agg(status, c), '{}'::jsonb) FROM (SELECT status, COUNT(*) c FROM base GROUP BY status) s),
    'by_outcome',       (SELECT COALESCE(jsonb_object_agg(outcome, qt), '{}'::jsonb) FROM outcomes),
    'by_user',          (SELECT COALESCE(jsonb_agg(to_jsonb(p.*) ORDER BY p.routes DESC), '[]'::jsonb) FROM per_user p),
    'is_admin',         v_is_admin
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- update_stop / candidates / stop_remove / delete (2 overloads)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION castor_route_update_stop(
  p_user_id          UUID,
  p_route_id         UUID,
  p_cliente_codigo   TEXT,
  p_outcome          TEXT,
  p_notes            TEXT,
  p_custom_days      INT,
  p_interaction_type TEXT DEFAULT NULL,
  p_next_contact_at  DATE DEFAULT NULL,
  p_next_action      TEXT DEFAULT NULL
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row     castor_route_saved%ROWTYPE;
  v_new     JSONB := '[]'::JSONB;
  v_elem    JSONB;
  v_open    INT := 0;
  v_done    INT := 0;
  v_total   INT := 0;
  v_is_admin BOOLEAN;
  v_itype   TEXT;
  v_next    DATE;
  v_allowed TEXT[] := ARRAY[
    'visitou','sem_contato','convertido','voltar_depois','negativo',
    'aguardando_resposta','pedido_em_negociacao',
    'nao_existe_mais','nao_interessado_permanente'
  ];
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok',false,'error','forbidden');
  END IF;
  IF p_outcome IS NOT NULL AND NOT (p_outcome = ANY(v_allowed)) THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_outcome');
  END IF;

  v_itype := COALESCE(NULLIF(btrim(p_interaction_type),''), 'visita_presencial');
  IF v_itype NOT IN ('visita_presencial','telefone','whatsapp','email','reuniao_online','outro') THEN
    v_itype := 'visita_presencial';
  END IF;

  IF p_next_contact_at IS NOT NULL THEN
    v_next := p_next_contact_at;
  ELSIF p_custom_days IS NOT NULL AND p_custom_days BETWEEN 1 AND 365 THEN
    v_next := (CURRENT_DATE + (p_custom_days || ' days')::INTERVAL)::DATE;
  ELSE
    v_next := NULL;
  END IF;
  IF p_outcome IN ('convertido','nao_existe_mais','nao_interessado_permanente') THEN
    v_next := NULL;
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_row.stops) LOOP
    v_total := v_total + 1;
    IF (v_elem->>'cliente_codigo') = p_cliente_codigo THEN
      IF p_outcome IS NULL THEN
        v_elem := v_elem - 'outcome' - 'visited_at' - 'notes' - 'interaction_type' - 'next_contact_at' - 'next_action';
      ELSE
        v_elem := v_elem
          || jsonb_build_object(
               'outcome',          p_outcome,
               'visited_at',       NOW(),
               'interaction_type', v_itype
             )
          || (CASE WHEN p_notes IS NOT NULL AND btrim(p_notes) <> ''
                    THEN jsonb_build_object('notes', p_notes) ELSE '{}'::jsonb END)
          || (CASE WHEN v_next IS NOT NULL
                    THEN jsonb_build_object('next_contact_at', to_char(v_next,'YYYY-MM-DD')) ELSE '{}'::jsonb END)
          || (CASE WHEN p_next_action IS NOT NULL AND btrim(p_next_action) <> ''
                    THEN jsonb_build_object('next_action', p_next_action) ELSE '{}'::jsonb END);
      END IF;
    END IF;
    IF (v_elem->>'outcome') IS NOT NULL THEN v_done := v_done + 1; END IF;
    v_new := v_new || jsonb_build_array(v_elem);
  END LOOP;

  v_open := v_total - v_done;

  UPDATE castor_route_saved SET
    stops        = v_new,
    status       = CASE
                     WHEN v_done = 0 THEN 'planejado'
                     WHEN v_open = 0 THEN 'concluido'
                     ELSE 'em_andamento'
                   END,
    completed_at = CASE WHEN v_open = 0 THEN NOW() ELSE NULL END
   WHERE id = p_route_id;

  IF p_outcome IS NOT NULL THEN
    PERFORM castor_client_interaction_add(
      p_user_id, p_cliente_codigo, v_itype, p_outcome,
      p_notes, v_next, NULL, p_next_action,
      p_route_id, 'route:' || p_route_id::TEXT || ':' || p_cliente_codigo
    );
  END IF;

  RETURN jsonb_build_object('ok',true,'route_id',p_route_id,'done',v_done,'total',v_total);
END; $$;

CREATE OR REPLACE FUNCTION castor_route_candidates(
  p_user_id   UUID,
  p_mode      TEXT,
  p_uf        TEXT,
  p_cidade    TEXT,
  p_limit     INT
)
RETURNS TABLE(
  cliente_codigo TEXT, a1_nome TEXT, a1_vend TEXT,
  a1_mun TEXT, a1_est TEXT, a1_end TEXT, a1_cep TEXT,
  status_real TEXT, urgencia_score INT,
  faturamento_alltime NUMERIC, ultimo_pedido DATE, dias_sem_pedido INT,
  porte_efetivo TEXT, lat DOUBLE PRECISION, lng DOUBLE PRECISION
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_role TEXT;
  v_vend TEXT;
  v_est  TEXT[];
  v_cid  TEXT[];
BEGIN
  SELECT s.role, s.vendor_code, s.estados, s.cidades
    INTO v_role, v_vend, v_est, v_cid
  FROM castor_user_scope(p_user_id) s;
  v_role := COALESCE(v_role,'vendedor');

  RETURN QUERY
  SELECT
    m.cliente_codigo, m.a1_nome, m.a1_vend,
    m.a1_mun, m.a1_est, m.a1_end, m.a1_cep,
    m.status_real, m.urgencia_score,
    m.faturamento_alltime, m.ultimo_pedido, m.dias_sem_pedido,
    m.porte_efetivo, g.lat, g.lng
  FROM castor_client_metrics_v2 m
  LEFT JOIN castor_geocode_cache g
    ON g.scope = 'municipio'
   AND g.query_key = upper(coalesce(m.a1_mun,'')) || '|' || upper(coalesce(m.a1_est,''))
   AND g.ok
  WHERE (v_role = 'admin' OR (
          (v_vend IS NULL OR m.a1_vend = v_vend)
          AND (v_est IS NULL OR upper(coalesce(m.a1_est,'')) = ANY(v_est))
          AND (v_cid IS NULL OR upper(coalesce(m.a1_mun,'')) = ANY(v_cid))
        ))
    AND (p_uf     IS NULL OR upper(coalesce(m.a1_est,'')) = upper(p_uf))
    AND (p_cidade IS NULL OR upper(coalesce(m.a1_mun,'')) = upper(p_cidade))
    AND CASE p_mode
          WHEN 'reactivation' THEN m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
          WHEN 'prospect_skip' THEN m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
          ELSE TRUE
        END
    AND m.pedidos_alltime >= 1
  ORDER BY (g.lat IS NULL AND g.lng IS NULL),
           m.urgencia_score DESC NULLS LAST,
           m.faturamento_alltime DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit,12), 30));
END; $$;

CREATE OR REPLACE FUNCTION castor_route_stop_remove(
  p_user_id        UUID,
  p_route_id       UUID,
  p_cliente_codigo TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row      castor_route_saved%ROWTYPE;
  v_new      JSONB := '[]'::JSONB;
  v_elem     JSONB;
  v_open     INT := 0;
  v_done     INT := 0;
  v_total    INT := 0;
  v_is_admin BOOLEAN;
  v_removed  BOOLEAN := false;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok',false,'error','forbidden');
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_row.stops) LOOP
    IF (v_elem->>'cliente_codigo') = p_cliente_codigo THEN
      v_removed := true;
      CONTINUE;
    END IF;
    v_total := v_total + 1;
    IF (v_elem->>'outcome') IS NOT NULL THEN v_done := v_done + 1; END IF;
    v_new := v_new || jsonb_build_array(v_elem);
  END LOOP;

  IF NOT v_removed THEN
    RETURN jsonb_build_object('ok',false,'error','stop_not_found');
  END IF;

  v_open := v_total - v_done;

  UPDATE castor_route_saved SET
    stops  = v_new,
    status = CASE
               WHEN v_total = 0         THEN 'cancelado'
               WHEN v_done  = 0         THEN 'planejado'
               WHEN v_open  = 0         THEN 'concluido'
               ELSE 'em_andamento'
             END,
    completed_at = CASE WHEN v_total > 0 AND v_open = 0 THEN NOW() ELSE NULL END
   WHERE id = p_route_id;

  RETURN jsonb_build_object('ok',true,'route_id',p_route_id,'total',v_total,'done',v_done);
END; $$;

CREATE OR REPLACE FUNCTION castor_route_delete(
  p_user_id   UUID,
  p_route_id  UUID,
  p_mode      TEXT
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row              castor_route_saved%ROWTYPE;
  v_is_admin         BOOLEAN;
  v_codes            TEXT[];
  v_followups_zeroed INT := 0;
  v_history_deleted  INT := 0;
  v_mode             TEXT := COALESCE(NULLIF(btrim(p_mode),''),'route_followups');
BEGIN
  IF v_mode NOT IN ('route_only','route_followups','route_history') THEN
    RETURN jsonb_build_object('ok',false,'error','mode_invalido');
  END IF;

  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok',false,'error','forbidden');
  END IF;

  SELECT COALESCE(array_agg(DISTINCT s->>'cliente_codigo'), '{}')
    INTO v_codes
    FROM jsonb_array_elements(COALESCE(v_row.stops,'[]'::jsonb)) s
   WHERE s->>'cliente_codigo' IS NOT NULL
     AND btrim(s->>'cliente_codigo') <> '';

  IF v_mode = 'route_history' AND array_length(v_codes,1) IS NOT NULL THEN
    DELETE FROM castor_client_interactions
     WHERE vendedor_user_id = v_row.user_id
       AND cliente_codigo  = ANY(v_codes);
    GET DIAGNOSTICS v_history_deleted = ROW_COUNT;

  ELSIF v_mode = 'route_followups' AND array_length(v_codes,1) IS NOT NULL THEN
    UPDATE castor_client_interactions
       SET next_contact_at = NULL
     WHERE vendedor_user_id = v_row.user_id
       AND cliente_codigo  = ANY(v_codes)
       AND next_contact_at IS NOT NULL
       AND next_contact_at >= CURRENT_DATE
       AND (outcome IS NULL
            OR outcome NOT IN ('convertido','nao_existe_mais','nao_interessado_permanente'));
    GET DIAGNOSTICS v_followups_zeroed = ROW_COUNT;
  END IF;

  DELETE FROM castor_route_saved WHERE id = p_route_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'mode',              v_mode,
    'route_id',          p_route_id,
    'clients_in_route',  COALESCE(array_length(v_codes,1),0),
    'followups_zeroed',  v_followups_zeroed,
    'history_deleted',   v_history_deleted
  );
END; $$;

CREATE OR REPLACE FUNCTION castor_route_delete(
  p_user_id  UUID,
  p_route_id UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
  RETURN castor_route_delete(p_user_id, p_route_id, 'route_followups');
END; $$;

-- ----------------------------------------------------------------------------
-- client_detail + overrides + interactions + followups + recent changes
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION castor_client_detail(
  p_user_id        UUID,
  p_cliente_codigo TEXT
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_scope        RECORD;
  v_client       JSONB;
  v_feedbacks    JSONB;
  v_routes       JSONB;
  v_visible      BOOLEAN;
  v_a1_vend      TEXT;
  v_a1_mun       TEXT;
  v_a1_est       TEXT;
  v_has_link     BOOLEAN;
BEGIN
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cliente_codigo obrigatorio');
  END IF;

  SELECT * INTO v_scope FROM castor_user_scope(p_user_id);

  SELECT to_jsonb(m.*), m.a1_vend, m.a1_mun, m.a1_est
    INTO v_client, v_a1_vend, v_a1_mun, v_a1_est
    FROM castor_client_metrics_v2 m
   WHERE m.cliente_codigo = p_cliente_codigo
   LIMIT 1;

  IF v_client IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cliente nao encontrado');
  END IF;

  IF v_scope.role = 'admin' THEN
    v_visible := TRUE;
  ELSE
    v_visible := (
      (v_scope.vendor_code IS NULL OR v_a1_vend = v_scope.vendor_code)
      AND (v_scope.estados IS NULL OR upper(coalesce(v_a1_est, '')) = ANY(v_scope.estados))
      AND (v_scope.cidades IS NULL OR upper(coalesce(v_a1_mun, '')) = ANY(v_scope.cidades))
    );

    IF NOT v_visible THEN
      SELECT EXISTS (
               SELECT 1 FROM castor_client_interactions i
                WHERE i.cliente_codigo = p_cliente_codigo
                  AND i.vendedor_user_id = p_user_id
             )
          OR EXISTS (
               SELECT 1 FROM castor_route_saved r
                WHERE r.user_id = p_user_id
                  AND r.stops @> jsonb_build_array(jsonb_build_object('cliente_codigo', p_cliente_codigo))
             )
          OR EXISTS (
               SELECT 1 FROM castor_visita_feedback f
                WHERE f.cliente_codigo = p_cliente_codigo
                  AND f.vendedor_user_id = p_user_id
             )
        INTO v_has_link;

      IF NOT v_has_link THEN
        BEGIN
          EXECUTE 'SELECT EXISTS (SELECT 1 FROM castor_client_status_override o '
               || 'WHERE o.cliente_codigo = $1 AND o.assigned_user_id = $2)'
            INTO v_has_link
            USING p_cliente_codigo, p_user_id;
        EXCEPTION
          WHEN undefined_table THEN v_has_link := FALSE;
          WHEN undefined_column THEN v_has_link := FALSE;
        END;
      END IF;

      IF v_has_link THEN
        v_visible := TRUE;
      END IF;
    END IF;
  END IF;

  IF NOT v_visible THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(f.*) ORDER BY f.visited_at DESC), '[]'::jsonb)
    INTO v_feedbacks
    FROM (
      SELECT id, cliente_codigo, vendedor_user_id, vendedor_codigo,
             visited_at, outcome, custom_days, next_contact_at, notes, created_at
        FROM castor_visita_feedback
       WHERE cliente_codigo = p_cliente_codigo
       ORDER BY visited_at DESC
       LIMIT 50
    ) f;

  SELECT COALESCE(jsonb_agg(to_jsonb(r.*) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_routes
    FROM (
      SELECT r.id, r.name, r.source, r.status, r.total_km, r.maps_url,
             r.created_at, r.updated_at, r.completed_at, r.user_id,
             (SELECT u.raw_user_meta_data->>'full_name' FROM auth.users u WHERE u.id = r.user_id) AS user_name,
             (SELECT jsonb_array_length(r.stops)) AS stops_count
        FROM castor_route_saved r
       WHERE r.stops @> jsonb_build_array(jsonb_build_object('cliente_codigo', p_cliente_codigo))
         AND (v_scope.role = 'admin' OR r.user_id = p_user_id)
       ORDER BY r.created_at DESC
       LIMIT 20
    ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'client', v_client,
    'feedbacks', v_feedbacks,
    'routes', v_routes
  );
END;
$$;

CREATE OR REPLACE FUNCTION castor_client_address_override_set(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_endereco       TEXT,
  p_cep            TEXT,
  p_municipio      TEXT,
  p_uf             TEXT,
  p_contato_nome   TEXT,
  p_contato_tel    TEXT,
  p_contato_email  TEXT,
  p_contato_whats  TEXT,
  p_notes          TEXT,
  p_lifecycle      TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_row castor_client_address_override%ROWTYPE;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','unauthenticated');
  END IF;
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok',false,'error','cliente_codigo_required');
  END IF;

  INSERT INTO castor_client_address_override(
    cliente_codigo, endereco, cep, municipio, uf,
    contato_nome, contato_tel, contato_email, contato_whats,
    notes, lifecycle_status, updated_by
  )
  VALUES (
    p_cliente_codigo,
    NULLIF(btrim(p_endereco),''),
    NULLIF(regexp_replace(coalesce(p_cep,''),'\D','','g'),''),
    NULLIF(btrim(upper(p_municipio)),''),
    NULLIF(btrim(upper(p_uf)),''),
    NULLIF(btrim(p_contato_nome),''),
    NULLIF(btrim(p_contato_tel),''),
    NULLIF(btrim(p_contato_email),''),
    NULLIF(btrim(p_contato_whats),''),
    NULLIF(btrim(p_notes),''),
    NULLIF(btrim(p_lifecycle),''),
    p_user_id
  )
  ON CONFLICT (cliente_codigo) DO UPDATE SET
    endereco         = COALESCE(NULLIF(btrim(EXCLUDED.endereco),''),         castor_client_address_override.endereco),
    cep              = COALESCE(NULLIF(EXCLUDED.cep,''),                     castor_client_address_override.cep),
    municipio        = COALESCE(NULLIF(EXCLUDED.municipio,''),               castor_client_address_override.municipio),
    uf               = COALESCE(NULLIF(EXCLUDED.uf,''),                      castor_client_address_override.uf),
    contato_nome     = COALESCE(NULLIF(EXCLUDED.contato_nome,''),            castor_client_address_override.contato_nome),
    contato_tel      = COALESCE(NULLIF(EXCLUDED.contato_tel,''),             castor_client_address_override.contato_tel),
    contato_email    = COALESCE(NULLIF(EXCLUDED.contato_email,''),           castor_client_address_override.contato_email),
    contato_whats    = COALESCE(NULLIF(EXCLUDED.contato_whats,''),           castor_client_address_override.contato_whats),
    notes            = COALESCE(NULLIF(EXCLUDED.notes,''),                   castor_client_address_override.notes),
    lifecycle_status = COALESCE(NULLIF(EXCLUDED.lifecycle_status,''),        castor_client_address_override.lifecycle_status),
    updated_by       = EXCLUDED.updated_by
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok',true,'data', to_jsonb(v_row));
END; $$;

CREATE OR REPLACE FUNCTION castor_client_address_override_get(
  p_cliente_codigo TEXT
) RETURNS castor_client_address_override
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql AS $$
  SELECT * FROM castor_client_address_override WHERE cliente_codigo = p_cliente_codigo;
$$;

CREATE OR REPLACE FUNCTION castor_client_status_set(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_lifecycle      TEXT,
  p_notes          TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','unauthenticated');
  END IF;
  IF p_lifecycle NOT IN ('ativo','encerrado','nao_interessado_permanente') THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_lifecycle');
  END IF;

  INSERT INTO castor_client_address_override(cliente_codigo, lifecycle_status, notes, updated_by)
  VALUES (p_cliente_codigo, p_lifecycle, NULLIF(btrim(p_notes),''), p_user_id)
  ON CONFLICT (cliente_codigo) DO UPDATE SET
    lifecycle_status = EXCLUDED.lifecycle_status,
    notes            = COALESCE(EXCLUDED.notes, castor_client_address_override.notes),
    updated_by       = EXCLUDED.updated_by;

  RETURN jsonb_build_object('ok',true,'cliente_codigo',p_cliente_codigo,'lifecycle',p_lifecycle);
END; $$;

CREATE OR REPLACE FUNCTION castor_client_interaction_add(
  p_user_id          UUID,
  p_cliente_codigo   TEXT,
  p_interaction_type TEXT,
  p_outcome          TEXT,
  p_notes            TEXT,
  p_next_contact_at  DATE,
  p_next_days        INT,
  p_next_action      TEXT,
  p_route_id         UUID,
  p_idempotency_key  TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row        castor_client_interactions%ROWTYPE;
  v_codigo     TEXT;
  v_next       DATE;
  v_existing   castor_client_interactions%ROWTYPE;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','unauthenticated');
  END IF;
  IF p_cliente_codigo IS NULL OR btrim(p_cliente_codigo) = '' THEN
    RETURN jsonb_build_object('ok',false,'error','cliente_codigo_required');
  END IF;
  IF p_interaction_type IS NULL OR p_interaction_type NOT IN (
    'visita_presencial','telefone','whatsapp','email','reuniao_online','outro'
  ) THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_interaction_type');
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT * INTO v_existing FROM castor_client_interactions WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object('ok',true,'data',to_jsonb(v_existing),'idempotent',true);
    END IF;
  END IF;

  SELECT codigo INTO v_codigo FROM castor_vendor_user WHERE user_id = p_user_id;

  IF p_next_contact_at IS NOT NULL THEN
    v_next := p_next_contact_at;
  ELSIF p_next_days IS NOT NULL AND p_next_days BETWEEN 1 AND 365 THEN
    v_next := (CURRENT_DATE + (p_next_days || ' days')::INTERVAL)::DATE;
  ELSE
    v_next := NULL;
  END IF;

  IF p_outcome IN ('convertido','nao_existe_mais','nao_interessado_permanente') THEN
    v_next := NULL;
  END IF;

  INSERT INTO castor_client_interactions(
    cliente_codigo, vendedor_user_id, vendedor_codigo, route_id,
    interaction_type, outcome, notes, next_contact_at, next_action,
    idempotency_key
  ) VALUES (
    p_cliente_codigo, p_user_id, v_codigo, p_route_id,
    p_interaction_type, NULLIF(p_outcome,''), NULLIF(btrim(p_notes),''),
    v_next, NULLIF(btrim(p_next_action),''),
    NULLIF(p_idempotency_key,'')
  )
  RETURNING * INTO v_row;

  IF v_row.outcome IS NOT NULL THEN
    BEGIN
      INSERT INTO castor_visita_feedback(
        cliente_codigo, vendedor_user_id, vendedor_codigo, visited_at,
        outcome, custom_days, next_contact_at, notes, idempotency_key
      ) VALUES (
        v_row.cliente_codigo, v_row.vendedor_user_id, v_row.vendedor_codigo, v_row.occurred_at,
        v_row.outcome, p_next_days, v_row.next_contact_at, v_row.notes,
        'interaction:' || v_row.id::TEXT
      );
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;
  END IF;

  IF p_outcome = 'nao_existe_mais' THEN
    PERFORM castor_client_status_set(p_user_id, p_cliente_codigo, 'encerrado', p_notes);
  ELSIF p_outcome = 'nao_interessado_permanente' THEN
    PERFORM castor_client_status_set(p_user_id, p_cliente_codigo, 'nao_interessado_permanente', p_notes);
  END IF;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(v_row));
END; $$;

CREATE OR REPLACE FUNCTION castor_client_interaction_list(
  p_user_id        UUID,
  p_cliente_codigo TEXT,
  p_limit          INT
) RETURNS TABLE(
  id UUID, cliente_codigo TEXT, vendedor_user_id UUID, vendedor_nome TEXT,
  route_id UUID, interaction_type TEXT, outcome TEXT,
  notes TEXT, occurred_at TIMESTAMPTZ, next_contact_at DATE, next_action TEXT
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE v_is_admin BOOLEAN;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  RETURN QUERY
  SELECT i.id, i.cliente_codigo, i.vendedor_user_id,
         COALESCE((u.raw_user_meta_data->>'name'), u.email) AS vendedor_nome,
         i.route_id, i.interaction_type, i.outcome,
         i.notes, i.occurred_at, i.next_contact_at, i.next_action
    FROM castor_client_interactions i
    LEFT JOIN auth.users u ON u.id = i.vendedor_user_id
   WHERE i.cliente_codigo = p_cliente_codigo
     AND (v_is_admin OR i.vendedor_user_id = p_user_id)
   ORDER BY i.occurred_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
END; $$;

CREATE OR REPLACE FUNCTION castor_client_pending_followups(
  p_user_id     UUID,
  p_days_ahead  INT,
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
    -- next_contact_at). Se a última interação resolveu/zerou o agendamento, o
    -- cliente sai da fila — não "volta" para uma interação antiga vencida.
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
  WHERE l.next_contact_at IS NOT NULL
    AND l.next_contact_at <= v_cap_date
    AND (v_is_admin OR l.vendedor_user_id = p_user_id)
    AND COALESCE(m.lifecycle_status,'ativo') NOT IN ('encerrado','nao_interessado_permanente')
  ORDER BY l.next_contact_at ASC NULLS LAST
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit,100), 500));
END; $$;

CREATE OR REPLACE FUNCTION castor_client_recent_changes(
  p_user_id     UUID,
  p_since_hours INT,
  p_limit       INT
) RETURNS TABLE(
  cliente_codigo  TEXT,
  cliente_nome    TEXT,
  ultima_atividade DATE,
  faturamento_alltime NUMERIC,
  status_real     TEXT,
  changed_at      TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE v_is_admin BOOLEAN; v_scope_vend TEXT;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;
  SELECT vendor_code INTO v_scope_vend FROM castor_user_scope(p_user_id);

  RETURN QUERY
  SELECT m.cliente_codigo, m.a1_nome, m.ultima_atividade,
         m.faturamento_alltime, m.status_real, fa.computed_at
    FROM castor_client_metrics_v2 m
    JOIN castor_metrics_alltime fa ON fa.cliente_codigo = m.cliente_codigo
   WHERE fa.computed_at >= NOW() - (GREATEST(1, COALESCE(p_since_hours,24)) || ' hours')::INTERVAL
     AND (v_is_admin OR v_scope_vend IS NULL OR m.a1_vend = v_scope_vend)
   ORDER BY fa.computed_at DESC, m.faturamento_alltime DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,30), 200));
END; $$;

CREATE OR REPLACE FUNCTION castor_admin_route_reassign(
  p_caller       UUID,
  p_route_id     UUID,
  p_new_user_id  UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_caller_role TEXT;
  v_new_role    TEXT;
  v_exists      BOOLEAN;
BEGIN
  IF p_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'caller obrigatorio');
  END IF;
  IF p_route_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'route_id obrigatorio');
  END IF;
  IF p_new_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'new_user_id obrigatorio');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'role', 'vendedor')
    INTO v_caller_role
    FROM auth.users u
   WHERE u.id = p_caller;

  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden: admin-only');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'role', 'vendedor')
    INTO v_new_role
    FROM auth.users u
   WHERE u.id = p_new_user_id;

  IF v_new_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'new_user_id nao existe');
  END IF;

  SELECT EXISTS(SELECT 1 FROM castor_route_saved WHERE id = p_route_id)
    INTO v_exists;
  IF NOT v_exists THEN
    RETURN jsonb_build_object('ok', false, 'error', 'route_not_found');
  END IF;

  UPDATE castor_route_saved
     SET user_id = p_new_user_id,
         updated_at = NOW()
   WHERE id = p_route_id;

  RETURN jsonb_build_object('ok', true, 'route_id', p_route_id, 'new_user_id', p_new_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION castor_route_saved_touch() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_save(UUID,TEXT,TEXT,JSONB,NUMERIC,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_save_unified(UUID,TEXT,TEXT,JSONB,NUMERIC,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_build_maps_url(DOUBLE PRECISION,DOUBLE PRECISION,JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_list(UUID,BOOLEAN,INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_detail(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_metrics(UUID, INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_update_stop(UUID,UUID,TEXT,TEXT,TEXT,INT,TEXT,DATE,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_candidates(UUID,TEXT,TEXT,TEXT,INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_stop_remove(UUID,UUID,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_delete(UUID,UUID,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_route_delete(UUID,UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_detail(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_address_override_set(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_address_override_get(TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_status_set(UUID,TEXT,TEXT,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_interaction_add(UUID,TEXT,TEXT,TEXT,TEXT,DATE,INT,TEXT,UUID,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_interaction_list(UUID,TEXT,INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_pending_followups(UUID,INT,INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_client_recent_changes(UUID,INT,INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION castor_admin_route_reassign(UUID, UUID, UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version)
VALUES ('010_routes_and_interactions') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP FUNCTION IF EXISTS castor_admin_route_reassign(UUID, UUID, UUID);
-- DROP FUNCTION IF EXISTS castor_client_recent_changes(UUID, INT, INT);
-- DROP FUNCTION IF EXISTS castor_client_pending_followups(UUID, INT, INT);
-- DROP FUNCTION IF EXISTS castor_client_interaction_list(UUID, TEXT, INT);
-- DROP FUNCTION IF EXISTS castor_client_interaction_add(UUID, TEXT, TEXT, TEXT, TEXT, DATE, INT, TEXT, UUID, TEXT);
-- DROP FUNCTION IF EXISTS castor_client_status_set(UUID, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS castor_client_address_override_get(TEXT);
-- DROP FUNCTION IF EXISTS castor_client_address_override_set(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS castor_client_detail(UUID, TEXT);
-- DROP FUNCTION IF EXISTS castor_route_delete(UUID, UUID);
-- DROP FUNCTION IF EXISTS castor_route_delete(UUID, UUID, TEXT);
-- DROP FUNCTION IF EXISTS castor_route_stop_remove(UUID, UUID, TEXT);
-- DROP FUNCTION IF EXISTS castor_route_candidates(UUID, TEXT, TEXT, TEXT, INT);
-- DROP FUNCTION IF EXISTS castor_route_update_stop(UUID, UUID, TEXT, TEXT, TEXT, INT, TEXT, DATE, TEXT);
-- DROP FUNCTION IF EXISTS castor_route_metrics(UUID, INT);
-- DROP FUNCTION IF EXISTS castor_route_detail(UUID, UUID);
-- DROP FUNCTION IF EXISTS castor_route_list(UUID, BOOLEAN, INT);
-- DROP FUNCTION IF EXISTS castor_route_build_maps_url(DOUBLE PRECISION, DOUBLE PRECISION, JSONB);
-- DROP FUNCTION IF EXISTS castor_route_save_unified(UUID, TEXT, TEXT, JSONB, NUMERIC, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS castor_route_save(UUID, TEXT, TEXT, JSONB, NUMERIC, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT);
-- DROP TRIGGER IF EXISTS castor_route_saved_touch_trg ON castor_route_saved;
-- DROP FUNCTION IF EXISTS castor_route_saved_touch();
-- DROP TABLE IF EXISTS castor_route_saved;
-- COMMIT;
