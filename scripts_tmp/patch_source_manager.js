// Patch idempotente do Castor-Source-Manager.json:
// adiciona as novas tabelas (sa1010, sb1010, sbm010, sd2010, sf4010, sx5010, sz1010)
// ao parser posicional, validações e lista da UI. Opera sobre o jsCode parseado
// (strings reais) para evitar problemas de escape JSON.
const fs = require('fs');
const path = require('path');

const FILE = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Source-Manager.json');
const raw = fs.readFileSync(FILE, 'utf8');
const wf = JSON.parse(raw);

const NEW_TABLES_LOWER = ['sa1010','sa3010','cc2010','za7010','sf2010','sc5010','sb1010','sbm010','sd2010','sf4010','sx5010','sz1010'];
const ALLOWED_OLD = "['sa3010','cc2010','za7010','sf2010','sc5010']";
const ALLOWED_NEW = "['" + NEW_TABLES_LOWER.join("','") + "']";
const ERRMSG_OLD = 'use sa3010|cc2010|za7010|sf2010|sc5010';
const ERRMSG_NEW = 'use ' + NEW_TABLES_LOWER.join('|');

const NEW_MAPS = [
  "  sa1010:  { cols: ['a1_codcli_raw','a1_nome','a1_nreduz','a1_pessoa','a1_cgc','a1_pricom','a1_ultcom','a1_vend','a1_risco','a1_lc','a1_sativ1','a1_end','a1_cep','a1_bairro','a1_est','a1_cod_mun','a1_mun','a1_ativo_raw','a1_inativo_raw'], pos: [1,2,3,4,5,6,7,8,9,10,19,20,21,22,23,24,26,27,28], types: { a1_pricom:'date', a1_ultcom:'date', a1_lc:'num' } },",
  "  sb1010:  { cols: ['b1_cod','b1_desc','b1_tipo','b1_um','b1_grupo','b1_prv1'], pos: [2,3,4,6,8,28], types: { b1_prv1:'num' } },",
  "  sbm010:  { cols: ['bm_grupo','bm_desc'], pos: [2,3] },",
  "  sd2010:  { cols: ['d2_item','d2_cod','d2_quant','d2_prcven','d2_total','d2_descon','d2_tes','d2_cf','d2_pedido','d2_cliente','d2_loja','d2_doc','d2_serie','d2_grupo','d2_emissao'], pos: [2,3,6,7,8,39,11,12,20,22,23,25,26,27,29], types: { d2_quant:'num', d2_prcven:'num', d2_total:'num', d2_descon:'num', d2_emissao:'date' } },",
  "  sf4010:  { cols: ['f4_codigo','f4_tipo','f4_cf','f4_texto'], pos: [2,3,10,12] },",
  "  sx5010:  { cols: ['x5_tabela','x5_chave','x5_descri'], pos: [2,3,4] },",
  "  sz1010:  { cols: ['z1_cod','z1_clicod','z1_loja','z1_statua','z1_statud','z1_riscoa','z1_riscod','z1_tpalt','z1_pedido','z1_usunom','z1_data','z1_hora'], pos: [2,3,4,5,6,7,8,9,10,11,12,13], types: { z1_data:'date' } }"
].join('\n');

// refreshSql como mapa (substitui o ternário antigo)
const NEW_REFRESH = "const REFRESH = { sf2010:'SELECT castor_refresh_metrics_sf();\\nSELECT castor_refresh_metrics_alltime();\\n', sc5010:'SELECT castor_refresh_metrics_sc();\\nSELECT castor_refresh_sc5_address();\\nSELECT castor_refresh_metrics_alltime();\\n', sd2010:'SELECT castor_refresh_metrics_sd2();\\n', sa1010:'SELECT castor_refresh_sa1010_derived();\\n' };\nconst refreshSql = REFRESH[table] || '';";

const log = [];
function getNode(name) { return (wf.nodes || []).find(n => n.name === name); }

function patchJsCode(nodeName, fn) {
  const node = getNode(nodeName);
  if (!node || !node.parameters || typeof node.parameters.jsCode !== 'string') {
    log.push(`SKIP ${nodeName}: sem jsCode`);
    return;
  }
  const before = node.parameters.jsCode;
  const after = fn(before);
  if (after === before) { log.push(`NOOP ${nodeName}: nada mudou`); return; }
  node.parameters.jsCode = after;
  log.push(`OK   ${nodeName}`);
}

// 1) Validações (allowed set + msg)
for (const nm of ['Validate replace', 'Validate ingest', 'Validate init', 'Build batch SQL']) {
  patchJsCode(nm, s => s.split(ALLOWED_OLD).join(ALLOWED_NEW).split(ERRMSG_OLD).join(ERRMSG_NEW));
}

// 2) Build list response — canonical + labels
patchJsCode('Build list response', s => {
  let out = s.replace(
    "const canonical = ['SA3010','CC2010','ZA7010','SF2010','SC5010'];",
    "const canonical = ['SA1010','SA3010','CC2010','ZA7010','SF2010','SC5010','SB1010','SBM010','SD2010','SF4010','SX5010','SZ1010'];"
  );
  out = out.replace(
    "const labels = { SA3010:'Vendedores', CC2010:'Municípios', SC5010:'Pedidos cab.', SF2010:'NF cab.', ZA7010:'TMKT / Leads' };",
    "const labels = { SA1010:'Clientes', SA3010:'Vendedores', CC2010:'Municípios', SC5010:'Pedidos cab.', SF2010:'NF cab.', ZA7010:'TMKT / Leads', SB1010:'Produtos', SBM010:'Grupos de produto', SD2010:'Itens NF (venda)', SF4010:'TES / CFOP', SX5010:'Ramos de atividade', SZ1010:'Status cliente' };"
  );
  return out;
});

// 3) Parse positional — injeta MAPS novos + troca refreshSql
patchJsCode('Parse positional', s => {
  let out = s;
  // injeta após a entrada sc5010 (que termina o objeto MAPS)
  const re = /(sc5010:[^\n]*c5_emissao:'date' \} \})\n(\};)/;
  if (re.test(out)) {
    out = out.replace(re, `$1,\n${NEW_MAPS}\n$2`);
  } else {
    throw new Error('Parse positional: âncora sc5010 do MAPS não encontrada');
  }
  // troca o ternário refreshSql por mapa
  const reR = /const refreshSql = \(table === 'sf2010'\)[\s\S]*?: '';/;
  if (reR.test(out)) {
    out = out.replace(reR, NEW_REFRESH);
  } else {
    throw new Error('Parse positional: refreshSql não encontrado');
  }
  return out;
});

// validação final: JSON serializa OK
const serialized = JSON.stringify(wf, null, 2);
JSON.parse(serialized); // sanity
fs.writeFileSync(FILE, serialized + '\n', 'utf8');
console.log(log.join('\n'));
console.log('\nArquivo gravado:', FILE);
