// Estende o snapshot do Panel-API com top_products, top_groups e sales_trend (escopados via RPC).
const fs = require('fs');
const path = require('path');
const FILE = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Panel-API.json');
const wf = JSON.parse(fs.readFileSync(FILE, 'utf8'));

const pg = wf.nodes.find(n => n.name === 'PG: snapshot');
const build = wf.nodes.find(n => n.name === 'Build snapshot');
if (!pg || !build) throw new Error('nós não encontrados');

let q = pg.parameters.query;

// 1) injeta CTE u (user_id) logo após "WITH "
if (!q.includes('u AS (SELECT')) {
  q = q.replace(
    'WITH scope AS (',
    "WITH u AS (\n  SELECT NULLIF('{{ $('Cache check').first().json.user_id }}','')::uuid AS uid\n),\nscope AS ("
  );
}

// 2) adiciona campos no agg (antes do total_clientes)
if (!q.includes('top_products')) {
  q = q.replace(
    "    (SELECT COUNT(*) FROM clientes) AS total_clientes,",
    "    (SELECT CASE WHEN uid IS NULL THEN NULL ELSE castor_top_products(uid, 20, NULL) END FROM u) AS top_products,\n" +
    "    (SELECT CASE WHEN uid IS NULL THEN NULL ELSE castor_top_groups(uid, 20) END FROM u) AS top_groups,\n" +
    "    (SELECT CASE WHEN uid IS NULL THEN NULL ELSE castor_monthly_trend(uid, NULL, 24) END FROM u) AS sales_trend,\n" +
    "    (SELECT COUNT(*) FROM clientes) AS total_clientes,"
  );
}
pg.parameters.query = q;

// 3) Build snapshot: adiciona top_products/top_groups/sales_trend ao objeto snapshot
let js = build.parameters.jsCode;
if (!js.includes('top_products')) {
  js = js.replace(
    "  municipios:r.municipios || []\n};",
    "  municipios:r.municipios || [],\n" +
    "  top_products: (r.top_products && r.top_products.produtos) || [],\n" +
    "  top_groups: (r.top_groups && r.top_groups.grupos) || [],\n" +
    "  sales_trend: (r.sales_trend && r.sales_trend.serie) || []\n};"
  );
  build.parameters.jsCode = js;
}

const out = JSON.stringify(wf, null, 2);
JSON.parse(out);
fs.writeFileSync(FILE, out + '\n', 'utf8');
console.log('Snapshot estendido. query len:', q.length, '| build len:', js.length);
console.log('tem top_products na query:', q.includes('top_products'));
console.log('tem u CTE:', q.includes('u AS (SELECT'));
