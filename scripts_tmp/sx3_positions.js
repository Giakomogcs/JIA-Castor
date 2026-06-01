// Extrai do dicionário SX3 a ordem física dos campos por tabela e cruza com a 1a linha do CSV.
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DICT = path.join(ROOT, 'SC3010 - Dicionário de Dados.csv');

const CSV_FILES = {
  CC2: 'CC2010.csv', SA1: 'SA1010.csv', SA3: 'SA3010.csv', SB1: 'SB1010.csv',
  SBM: 'SBM010.csv', SC5: 'SC5010.csv', SC6: 'SC6010.csv', SF2: 'SF2010.csv',
  SD2: 'SD2010.csv', SF4: 'SF4010.csv', SX5: 'SX5010.csv', SZ1: 'SZ1010.csv', ZA7: 'ZA7010.csv',
};

const INTEREST = {
  SA1: ['A1_FILIAL','A1_COD','A1_LOJA','A1_NOME','A1_NREDUZ','A1_END','A1_BAIRRO','A1_MUN','A1_EST','A1_CEP','A1_COD_MUN','A1_TEL','A1_EMAIL','A1_CGC','A1_VEND','A1_USTATUS','A1_MSBLQL','A1_RISCO','A1_SATIV1','A1_CONTATO','A1_LC','A1_DTULTNF','A1_PESSOA'],
  SB1: ['B1_FILIAL','B1_COD','B1_DESC','B1_TIPO','B1_GRUPO','B1_UM','B1_PRV1','B1_MSBLQL','B1_DTREFP1'],
  SBM: ['BM_FILIAL','BM_GRUPO','BM_DESC'],
  SC6: ['C6_FILIAL','C6_ITEM','C6_PRODUTO','C6_DESCRI','C6_QTDVEN','C6_PRCVEN','C6_VALOR','C6_NUM','C6_CLI','C6_LOJA','C6_TES','C6_PRUNIT','C6_NOTA','C6_SERIE','C6_QTDENT','C6_ENTREG'],
  SD2: ['D2_FILIAL','D2_ITEM','D2_COD','D2_QUANT','D2_PRCVEN','D2_TOTAL','D2_PRUNIT','D2_TES','D2_CF','D2_DOC','D2_SERIE','D2_CLIENTE','D2_LOJA','D2_EMISSAO','D2_GRUPO','D2_VEND1','D2_PEDIDO','D2_ITEMPV','D2_CUSTO1','D2_DESCON','D2_LOCAL'],
  SF4: ['F4_FILIAL','F4_CODIGO','F4_TIPO','F4_TEXTO','F4_DUPLIC','F4_ESTOQUE','F4_CF','F4_DESCRI'],
  SX5: ['X5_FILIAL','X5_TABELA','X5_CHAVE','X5_DESCRI','X5_DESCSPA','X5_DESCENG'],
  SZ1: [],
};

function splitLine(line) {
  const out = []; let cur = ''; let inQ = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') { if (inQ && line[i + 1] === '"') { cur += '"'; i++; } else inQ = !inQ; }
    else if (ch === ';' && !inQ) { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out.map(s => s.trim());
}

function loadDict() {
  const txt = fs.readFileSync(DICT, 'latin1');
  const lines = txt.split(/\r?\n/);
  const tables = {};
  for (const line of lines) {
    if (!line) continue;
    const c = splitLine(line);
    if (c.length < 6) continue;
    const [tbl, ordem, field, type, size, dec] = c;
    if (!tbl || !field) continue;
    (tables[tbl] = tables[tbl] || []).push({ ordem, field, type, size, dec });
  }
  return tables;
}

function ordemKey(o) { o = (o || '').padEnd(2, ' '); return o.charCodeAt(0) * 256 + o.charCodeAt(1); }

function firstCsvCols(t) {
  const f = CSV_FILES[t]; if (!f) return null;
  const p = path.join(ROOT, f); if (!fs.existsSync(p)) return null;
  const fd = fs.openSync(p, 'r');
  const buf = Buffer.alloc(200000);
  const n = fs.readSync(fd, buf, 0, buf.length, 0);
  fs.closeSync(fd);
  let s = buf.slice(0, n).toString('latin1');
  const nl = s.indexOf('\n'); if (nl >= 0) s = s.slice(0, nl);
  s = s.replace(/\r$/, '');
  return splitLine(s);
}

const tables = loadDict();
const targets = ['SA1','SB1','SBM','SC6','SD2','SF4','SX5','SZ1','CC2','SA3','SC5','SF2','ZA7'];
for (const t of targets) {
  console.log('='.repeat(72));
  let fields = tables[t];
  if (!fields) { console.log(`${t}: NÃO encontrado no SX3`); continue; }
  fields = fields.slice().sort((a, b) => ordemKey(a.ordem) - ordemKey(b.ordem));
  const csv = firstCsvCols(t);
  console.log(`${t}: ${fields.length} campos SX3 | colunas 1a linha CSV: ${csv ? csv.length : '?'}`);
  const interest = new Set(INTEREST[t] || []);
  fields.forEach((f, i) => {
    const pos = i + 1;
    if (interest.size && !interest.has(f.field)) return;
    const sample = csv && pos - 1 < csv.length ? JSON.stringify(csv[pos - 1]) : '';
    console.log(`  [${String(pos).padStart(3)}] ${f.ordem.padStart(2)} ${f.field.padEnd(12)} ${f.type} ${f.size}.${f.dec}  ${interest.has(f.field) ? '<<< ' + sample : ''}`);
  });
  if (csv) console.log(`  ...últimas 5 colunas CSV: ${JSON.stringify(csv.slice(-5))} (total ${csv.length})`);
}
