-- ============================================================
-- 040 — Enriquecimento do cache de CNPJ (Receita Federal)
-- ============================================================
-- Contexto: agora que o SA1010 foi ingerido, TODO cliente tem A1_CGC (CNPJ).
-- O subflow `Consultar CNPJ` (BrasilAPI + fallback ReceitaWS) já guardava o
-- `payload` JSONB cru, mas só extraía 4 colunas (razao_social, porte, porte_rf,
-- cnae_principal, situacao_cadastral). Isso obrigava o agente a "garimpar" o
-- JSONB para analisar CNAE, capital, sócios, idade da empresa etc.
--
-- Esta migração adiciona colunas ESTRUTURADAS derivadas do cadastro RF para o
-- agente fazer análises mais ricas (porte vs faturamento, tempo de empresa,
-- CNAE para cross-sell, situação cadastral como risco, sócios para relacionamento).
--
-- IMPORTANTE: processos / problemas JUDICIAIS **não** vêm da Receita Federal.
-- BrasilAPI e ReceitaWS são gratuitas e expõem APENAS dados cadastrais.
-- Para litígios é preciso um provedor PAGO (Escavador, Jusbrasil, Serasa).
-- Deixamos as colunas-gancho (`tem_processos`, `processos_resumo`) NULL e
-- documentadas; o agente NUNCA deve inventar status judicial.
-- ============================================================

BEGIN;

ALTER TABLE castor_cnpj_cache
  ADD COLUMN IF NOT EXISTS nome_fantasia       TEXT,
  ADD COLUMN IF NOT EXISTS cnae_descricao      TEXT,
  ADD COLUMN IF NOT EXISTS cnaes_secundarios   JSONB,   -- [{codigo,descricao}, ...]
  ADD COLUMN IF NOT EXISTS natureza_juridica   TEXT,
  ADD COLUMN IF NOT EXISTS capital_social      NUMERIC,
  ADD COLUMN IF NOT EXISTS data_abertura       DATE,
  ADD COLUMN IF NOT EXISTS idade_anos          INT,     -- anos desde data_abertura (snapshot do fetch)
  ADD COLUMN IF NOT EXISTS simples_optante     BOOLEAN,
  ADD COLUMN IF NOT EXISTS mei_optante         BOOLEAN,
  ADD COLUMN IF NOT EXISTS municipio           TEXT,
  ADD COLUMN IF NOT EXISTS uf                  TEXT,
  ADD COLUMN IF NOT EXISTS bairro              TEXT,
  ADD COLUMN IF NOT EXISTS cep                 TEXT,
  ADD COLUMN IF NOT EXISTS logradouro          TEXT,
  ADD COLUMN IF NOT EXISTS telefone            TEXT,
  ADD COLUMN IF NOT EXISTS email               TEXT,
  ADD COLUMN IF NOT EXISTS socios              JSONB,   -- [{nome,qualificacao,faixa_etaria}, ...]
  ADD COLUMN IF NOT EXISTS qtd_socios          INT,
  ADD COLUMN IF NOT EXISTS motivo_situacao     TEXT,
  ADD COLUMN IF NOT EXISTS data_situacao       DATE,
  -- ganchos para integração JUDICIAL futura (provedor pago) — ficam NULL por ora
  ADD COLUMN IF NOT EXISTS tem_processos       BOOLEAN,
  ADD COLUMN IF NOT EXISTS processos_resumo    JSONB;

COMMENT ON COLUMN castor_cnpj_cache.tem_processos IS
  'NULL = não consultado (RF não fornece). Requer provedor pago (Escavador/Jusbrasil). Nunca inferir.';
COMMENT ON COLUMN castor_cnpj_cache.idade_anos IS
  'Anos desde data_abertura no momento do fetch. Recalcular quando o cache renovar.';

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('040_cnpj_enrich') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
