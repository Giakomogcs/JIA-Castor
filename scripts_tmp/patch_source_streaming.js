// Estende o caminho de STREAMING do Source-Manager para as 7 novas tabelas:
// 1) "Build batch SQL": MAPS += sa1010/sb1010/sbm010/sd2010/sf4010/sx5010/sz1010
// 2) "Build finish SQL": refresh para sd2010 e sa1010
const fs = require('fs');
const path = require('path');
const FILE = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Source-Manager.json');
const wf = JSON.parse(fs.readFileSync(FILE, 'utf8'));

const batch = wf.nodes.find(n => n.name === 'Build batch SQL');
const finish = wf.nodes.find(n => n.name === 'Build finish SQL');
if (!batch || !finish) throw new Error('nós não encontrados');

// ---- 1) Build batch SQL: substituir o objeto MAPS por um com as 12 tabelas ----
let bjs = batch.parameters.jsCode;
const NEW_MAPS =
  "const MAPS={" +
  "sa3010:{cols:['a3_cod','a3_nome','a3_nreduz'],types:['str','str','str']}," +
  "cc2010:{cols:['cc2_est','cc2_codmun','cc2_mun'],types:['str','str','str']}," +
  "za7010:{cols:['za7_data','za7_hora','za7_operad','za7_nomeop','za7_assunto','za7_contato','za7_cliente','za7_nome_cli','za7_vend','za7_compl'],types:['date','str','str','str','str','str','str','str','str','str']}," +
  "sf2010:{cols:['f2_doc','f2_serie','f2_cliente','f2_loja','f2_emissao','f2_valor'],types:['str','str','str','str','date','num']}," +
  "sc5010:{cols:['c5_num','c5_cliente','c5_loja','c5_nome','c5_vend','c5_emissao','c5_le_raw'],types:['str','str','str','str','str','date','str']}," +
  "sa1010:{cols:['a1_codcli_raw','a1_nome','a1_nreduz','a1_pessoa','a1_cgc','a1_pricom','a1_ultcom','a1_vend','a1_risco','a1_lc','a1_sativ1','a1_end','a1_cep','a1_bairro','a1_est','a1_cod_mun','a1_mun','a1_ativo_raw','a1_inativo_raw'],types:['str','str','str','str','str','date','date','str','str','num','str','str','str','str','str','str','str','str','str']}," +
  "sb1010:{cols:['b1_cod','b1_desc','b1_tipo','b1_um','b1_grupo','b1_prv1'],types:['str','str','str','str','str','num']}," +
  "sbm010:{cols:['bm_grupo','bm_desc'],types:['str','str']}," +
  "sd2010:{cols:['d2_item','d2_cod','d2_quant','d2_prcven','d2_total','d2_descon','d2_tes','d2_cf','d2_pedido','d2_cliente','d2_loja','d2_doc','d2_serie','d2_grupo','d2_emissao'],types:['str','str','num','num','num','num','str','str','str','str','str','str','str','str','date']}," +
  "sf4010:{cols:['f4_codigo','f4_tipo','f4_cf','f4_texto'],types:['str','str','str','str']}," +
  "sx5010:{cols:['x5_tabela','x5_chave','x5_descri'],types:['str','str','str']}," +
  "sz1010:{cols:['z1_cod','z1_clicod','z1_loja','z1_statua','z1_statud','z1_riscoa','z1_riscod','z1_tpalt','z1_pedido','z1_usunom','z1_data','z1_hora'],types:['str','str','str','str','str','str','str','str','str','str','date','str']}" +
  "};";

// localizar "const MAPS={...};const spec=" e trocar só o objeto MAPS
const startTok = 'const MAPS={';
const endTok = '};\nconst spec=';
const altEndTok = '};const spec=';
let s = bjs.indexOf(startTok);
if (s === -1) throw new Error('MAPS não encontrado em Build batch SQL');
let e = bjs.indexOf(endTok, s);
let endLen = endTok.length;
if (e === -1) { e = bjs.indexOf(altEndTok, s); endLen = altEndTok.length; }
if (e === -1) throw new Error('fim do MAPS/spec não encontrado');
// reconstrói: NEW_MAPS já inclui "};" final; manter "const spec="
bjs = bjs.slice(0, s) + NEW_MAPS + '\nconst spec=' + bjs.slice(e + endLen);
batch.parameters.jsCode = bjs;

// ---- 2) Build finish SQL: refresh para sd2010 e sa1010 ----
let fjs = finish.parameters.jsCode;
const oldRefresh = "const refreshFns=table==='sf2010'?['castor_refresh_metrics_sf','castor_refresh_metrics_alltime']:table==='sc5010'?['castor_refresh_metrics_sc','castor_refresh_sc5_address','castor_refresh_metrics_alltime']:null;";
const newRefresh = "const refreshFns=table==='sf2010'?['castor_refresh_metrics_sf','castor_refresh_metrics_alltime']:table==='sc5010'?['castor_refresh_metrics_sc','castor_refresh_sc5_address','castor_refresh_metrics_alltime']:table==='sd2010'?['castor_refresh_metrics_sd2']:table==='sa1010'?['castor_refresh_sa1010_derived']:null;";
if (fjs.includes(oldRefresh)) {
  fjs = fjs.replace(oldRefresh, newRefresh);
  finish.parameters.jsCode = fjs;
} else if (fjs.includes("table==='sd2010'")) {
  console.log('finish já tem sd2010 — skip');
} else {
  throw new Error('refreshFns base não encontrado em Build finish SQL');
}

const out = JSON.stringify(wf, null, 2);
JSON.parse(out);
fs.writeFileSync(FILE, out + '\n', 'utf8');
console.log('batch tem sd2010:', batch.parameters.jsCode.includes('sd2010'));
console.log('batch tem sa1010:', batch.parameters.jsCode.includes('a1_codcli_raw'));
console.log('finish tem sd2010 refresh:', finish.parameters.jsCode.includes("table==='sd2010'"));
