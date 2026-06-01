// Imprime cada coluna (índice 1-based) da 1a linha de dados de um CSV posicional,
// para alinhamento manual contra o dicionário SX3.
// Uso: node csv_index.js SC6010.csv 60
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

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

const file = process.argv[2];
const limit = parseInt(process.argv[3] || '80', 10);
const skip = parseInt(process.argv[4] || '0', 10); // pular N linhas (pra pegar amostra diferente)
const fd = fs.openSync(path.join(ROOT, file), 'r');
const buf = Buffer.alloc(2000000);
const n = fs.readSync(fd, buf, 0, buf.length, 0);
fs.closeSync(fd);
let txt = buf.slice(0, n).toString('latin1');
const lines = txt.split(/\r?\n/).filter(l => l.length);
const line = lines[skip];
let cols = splitLine(line);
if (cols[0]) cols[0] = cols[0].replace(/^\uFEFF|^ï»¿/, '');
console.log(`${file}: ${cols.length} colunas (linha ${skip})`);
cols.slice(0, limit).forEach((c, i) => console.log(`  [${String(i + 1).padStart(3)}] ${JSON.stringify(c)}`));
