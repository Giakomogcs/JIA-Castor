// Adiciona 6 tools Postgres ao Castor-Agent-IA.json chamando as novas RPCs da migration 037.
// Idempotente: se a tool já existe (por name), não duplica.
const fs = require('fs');
const path = require('path');
const FILE = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Agent-IA.json');
const wf = JSON.parse(fs.readFileSync(FILE, 'utf8'));

const PG_CRED = { id: 'jFjeYH6Nt3aRNkoM', name: 'Supabase_database' };
const AGENT = 'RAG AI Agent';

function tool(name, id, y, desc, query) {
  return {
    parameters: {
      descriptionType: 'manual',
      toolDescription: desc,
      operation: 'executeQuery',
      query,
      options: {
        queryReplacement: "={{ $fromAI('input', 'JSON string com os parâmetros da tool.', 'string') }}",
      },
    },
    type: 'n8n-nodes-base.postgresTool',
    typeVersion: 2.5,
    position: [29136, y],
    id,
    name,
    credentials: { postgres: PG_CRED },
  };
}

const NEW = [
  tool('get_product_mix', 'a1b2c3d4-0001-4a01-9001-000000000001', 18640,
    "Mostra O QUE UM CLIENTE COMPRA: top produtos (por valor faturado) e resumo por grupo de produto, com base nas NOTAS FISCAIS de saída (apenas itens de VENDA — bonificação/devolução já são excluídas via CFOP). Respeita o scope do vendedor. USE WHEN 'o que o cliente X compra', 'mix de produtos do cliente', 'principais itens do cliente Y', 'em quais grupos ele compra'.\n\nParâmetros (JSON string em \"$1\"):\n{\"user_id\":\"<UUID>\",\"cliente_codigo\":\"<A1_COD||A1_LOJA, 8 dígitos>\",\"limit\":15}\n\nDevolve: produtos[] (produto, b1_desc, grupo, grupo_desc, qtd_total, valor_total, n_notas, primeira_compra, ultima_compra) e grupos[] (grupo, grupo_desc, valor_total, qtd_total, n_produtos).",
    "WITH p AS (SELECT $1::jsonb AS body)\nSELECT castor_product_mix(\n  (p.body->>'user_id')::uuid,\n  (p.body->>'cliente_codigo'),\n  COALESCE(NULLIF(p.body->>'limit','')::int, 15)\n) AS result FROM p;"),

  tool('get_top_products', 'a1b2c3d4-0002-4a02-9002-000000000002', 18800,
    "RANKING dos produtos mais vendidos (por valor faturado de VENDA). Admin vê o ranking global; vendedor vê apenas a carteira dele. Pode filtrar por um grupo específico. USE WHEN 'produtos mais vendidos', 'top produtos', 'o que mais sai', 'ranking de itens', 'campeões de venda no grupo X'.\n\nParâmetros (JSON string em \"$1\"):\n{\"user_id\":\"<UUID>\",\"limit\":20,\"grupo\":\"<código BM_GRUPO opcional>\"}\n\nDevolve produtos[] com produto, b1_desc, grupo, grupo_desc, qtd_total, valor_total, n_clientes, ultima_venda.",
    "WITH p AS (SELECT $1::jsonb AS body)\nSELECT castor_top_products(\n  (p.body->>'user_id')::uuid,\n  COALESCE(NULLIF(p.body->>'limit','')::int, 20),\n  NULLIF(p.body->>'grupo','')\n) AS result FROM p;"),

  tool('get_top_groups', 'a1b2c3d4-0003-4a03-9003-000000000003', 18960,
    "RANKING dos grupos de produto mais vendidos (por valor faturado de VENDA). Admin = global; vendedor = carteira dele. USE WHEN 'grupos que mais vendem', 'categorias mais fortes', 'ranking por grupo de produto', 'onde está meu faturamento por categoria'.\n\nParâmetros (JSON string em \"$1\"):\n{\"user_id\":\"<UUID>\",\"limit\":20}\n\nDevolve grupos[] com grupo, grupo_desc, qtd_total, valor_total, n_clientes, n_produtos.",
    "WITH p AS (SELECT $1::jsonb AS body)\nSELECT castor_top_groups(\n  (p.body->>'user_id')::uuid,\n  COALESCE(NULLIF(p.body->>'limit','')::int, 20)\n) AS result FROM p;"),

  tool('get_sales_trend', 'a1b2c3d4-0004-4a04-9004-000000000004', 19120,
    "TENDÊNCIA de faturamento MÊS A MÊS (apenas vendas, CFOP de venda). Se passar cliente_codigo, retorna a série daquele cliente; sem cliente, retorna o total (admin) ou a carteira do vendedor. USE WHEN 'evolução de faturamento', 'tendência mensal', 'está caindo ou crescendo', 'histórico mês a mês do cliente X', 'meu faturamento nos últimos meses'.\n\nParâmetros (JSON string em \"$1\"):\n{\"user_id\":\"<UUID>\",\"cliente_codigo\":\"<opcional>\",\"months\":24}\n\nDevolve serie[] com ym ('YYYY-MM'), faturamento, qtd_itens, n_notas.",
    "WITH p AS (SELECT $1::jsonb AS body)\nSELECT castor_monthly_trend(\n  (p.body->>'user_id')::uuid,\n  NULLIF(p.body->>'cliente_codigo',''),\n  COALESCE(NULLIF(p.body->>'months','')::int, 24)\n) AS result FROM p;"),

  tool('get_crosssell_suggestions', 'a1b2c3d4-0005-4a05-9005-000000000005', 19280,
    "Sugere CROSS-SELL para um cliente: grupos de produto que clientes do MESMO RAMO de atividade compram e que este cliente AINDA NÃO compra, ordenados por penetração (quantos clientes do ramo compram). USE WHEN 'o que mais posso oferecer pro cliente X', 'sugestão de cross-sell', 'o que clientes parecidos compram que ele não compra', 'oportunidades de venda pra esse cliente'.\n\nParâmetros (JSON string em \"$1\"):\n{\"user_id\":\"<UUID>\",\"cliente_codigo\":\"<obrigatório>\",\"limit\":8}\n\nDevolve ramo e sugestoes[] com grupo, grupo_desc, clientes_compram, valor_total. Trate como SUGESTÃO (não garantia).",
    "WITH p AS (SELECT $1::jsonb AS body)\nSELECT castor_crosssell(\n  (p.body->>'user_id')::uuid,\n  (p.body->>'cliente_codigo'),\n  COALESCE(NULLIF(p.body->>'limit','')::int, 8)\n) AS result FROM p;"),

  tool('get_client_status_history', 'a1b2c3d4-0006-4a06-9006-000000000006', 19440,
    "Histórico de MUDANÇAS DE STATUS/RISCO do cliente antes/depois de vendas (tabela SZ1010 do Protheus). USE WHEN 'como variou o status do cliente X', 'ele já foi bloqueado antes', 'histórico de risco do cliente', 'esse cliente estava inativo e voltou?'.\n\nParâmetros (JSON string em \"$1\"):\n{\"user_id\":\"<UUID>\",\"cliente_codigo\":\"<obrigatório>\",\"limit\":30}\n\nDevolve historico[] com z1_data, z1_hora, z1_statua (antes), z1_statud (depois), z1_riscoa, z1_riscod, z1_pedido, z1_usunom.",
    "WITH p AS (SELECT $1::jsonb AS body)\nSELECT castor_client_status_history(\n  (p.body->>'user_id')::uuid,\n  (p.body->>'cliente_codigo'),\n  COALESCE(NULLIF(p.body->>'limit','')::int, 30)\n) AS result FROM p;"),
];

const existing = new Set(wf.nodes.map(n => n.name));
let added = 0;
for (const t of NEW) {
  if (existing.has(t.name)) { console.log('skip (existe):', t.name); continue; }
  wf.nodes.push(t);
  wf.connections[t.name] = { ai_tool: [[{ node: AGENT, type: 'ai_tool', index: 0 }]] };
  added++;
  console.log('add:', t.name);
}

const out = JSON.stringify(wf, null, 2);
JSON.parse(out);
fs.writeFileSync(FILE, out + '\n', 'utf8');
console.log(`\n${added} tools adicionadas. Total nodes: ${wf.nodes.length}`);
