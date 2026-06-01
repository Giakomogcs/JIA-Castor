// Simula o Parse positional para validar o mapa de uma tabela contra dados reais.
// Uso: node verify_map.js sd2010 SD2010.csv 3
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

const MAPS = {
  sd2010: { cols: ['d2_item','d2_cod','d2_quant','d2_prcven','d2_total','d2_descon','d2_tes','d2_cf','d2_pedido','d2_cliente','d2_loja','d2_doc','d2_serie','d2_grupo','d2_emissao'], pos: [2,3,6,7,8,39,11,12,20,22,23,25,26,27,29], types: { d2_quant:'num', d2_prcven:'num', d2_total:'num', d2_descon:'num', d2_emissao:'date' } },
  sf4010: { cols: ['f4_codigo','f4_tipo','f4_cf','f4_texto'], pos: [2,3,10,12] },
  sx5010: { cols: ['x5_tabela','x5_chave','x5_descri'], pos: [2,3,4] },
  sz1010: { cols: ['z1_cod','z1_clicod','z1_loja','z1_statua','z1_statud','z1_riscoa','z1_riscod','z1_tpalt','z1_pedido','z1_usunom','z1_data','z1_hora'], pos: [2,3,4,5,6,7,8,9,10,11,12,13], types: { z1_data:'date' } },
};

function splitLine(line, sep) {
  const out = []; let cur = ''; let inQ = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') { if (inQ && line[i + 1] === '"') { cur += '"'; i++; } else inQ = !inQ; }
    else if (ch === sep && !inQ) { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out.map(s => s.trim());
}
function parseProtheusDate(s) {
  s = String(s || '').trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/); if (m) return m[1] + '-' + m[2] + '-' + m[3];
  m = s.match(/^(\d{2})\/(\d{2})\/(\d{4})/); if (m) return m[3] + '-' + m[2] + '-' + m[1];
  const d = s.replace(/[^0-9]/g, '');
  if (d.length === 8) return d.slice(0, 4) + '-' + d.slice(4, 6) + '-' + d.slice(6, 8);
  return null;
}
function parseNum(s) {
  s = String(s || '').trim();
  if (s.includes(',') && s.includes('.')) s = s.replace(/\./g, '').replace(',', '.');
  else if (s.includes(',')) s = s.replace(',', '.');
  s = s.replace(/[^0-9.\-]/g, '');
  const n = +s; return Number.isFinite(n) ? n : 0;
}

const table = process.argv[2];
const file = process.argv[3];
const limit = parseInt(process.argv[4] || '3', 10);
const spec = MAPS[table];
const fd = fs.openSync(path.join(ROOT, file), 'r');
const buf = Buffer.alloc(4000000);
const n = fs.readSync(fd, buf, 0, buf.length, 0);
fs.closeSync(fd);
const lines = buf.slice(0, n).toString('latin1').split(/\r?\n/).filter(l => l.length);
const NEED = Math.max(...spec.pos);
for (let li = 0; li < limit && li < lines.length; li++) {
  let cols = splitLine(lines[li], ';');
  if (cols[0]) cols[0] = cols[0].replace(/^\uFEFF|^ï»¿/, '');
  console.log(`--- row ${li} (cols=${cols.length}, need ${NEED}) ---`);
  spec.cols.forEach((c, i) => {
    const raw = cols[spec.pos[i] - 1] != null ? cols[spec.pos[i] - 1] : '';
    const t = spec.types && spec.types[c];
    let v = raw;
    if (t === 'date') v = parseProtheusDate(raw);
    else if (t === 'num') v = parseNum(raw);
    console.log(`   ${c.padEnd(11)} [pos ${spec.pos[i]}] = ${JSON.stringify(v)}`);
  });
}
