// Mini-leitor de XLSX (sem dependências): descompacta o zip via zlib e parseia
// sharedStrings + primeira planilha. Imprime as primeiras N linhas como arrays.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');

function readZipEntries(buf) {
  // localizar End of Central Directory
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('EOCD não encontrado');
  const cdCount = buf.readUInt16LE(eocd + 10);
  let off = buf.readUInt32LE(eocd + 16);
  const entries = {};
  for (let n = 0; n < cdCount; n++) {
    if (buf.readUInt32LE(off) !== 0x02014b50) break;
    const method = buf.readUInt16LE(off + 10);
    const compSize = buf.readUInt32LE(off + 20);
    const nameLen = buf.readUInt16LE(off + 28);
    const extraLen = buf.readUInt16LE(off + 30);
    const commentLen = buf.readUInt16LE(off + 32);
    const lho = buf.readUInt32LE(off + 42);
    const name = buf.slice(off + 46, off + 46 + nameLen).toString('utf8');
    // local header
    const lNameLen = buf.readUInt16LE(lho + 26);
    const lExtraLen = buf.readUInt16LE(lho + 28);
    const dataStart = lho + 30 + lNameLen + lExtraLen;
    const comp = buf.slice(dataStart, dataStart + compSize);
    let data;
    if (method === 0) data = comp;
    else if (method === 8) data = zlib.inflateRawSync(comp);
    else throw new Error('método zip não suportado: ' + method);
    entries[name] = data;
    off += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

function parseSharedStrings(xml) {
  if (!xml) return [];
  const out = [];
  const re = /<si\b[\s\S]*?<\/si>|<si\/>/g;
  let m;
  while ((m = re.exec(xml))) {
    const si = m[0];
    // concatena todos os <t>...</t>
    const tre = /<t[^>]*>([\s\S]*?)<\/t>/g;
    let t, s = '';
    while ((t = tre.exec(si))) s += t[1];
    out.push(decodeXml(s));
  }
  return out;
}

function decodeXml(s) {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
          .replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, d) => String.fromCharCode(+d))
          .replace(/&amp;/g, '&');
}

function colToIdx(ref) { // "B3" -> 1 (0-based col)
  const m = /^([A-Z]+)/.exec(ref); if (!m) return 0;
  let n = 0; for (const ch of m[1]) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

function parseSheet(xml, shared, maxRows) {
  const rows = [];
  const rowRe = /<row\b[^>]*>([\s\S]*?)<\/row>/g;
  let rm;
  while ((rm = rowRe.exec(xml)) && rows.length < maxRows) {
    const cells = [];
    const cRe = /<c\b([^>]*)(?:\/>|>([\s\S]*?)<\/c>)/g;
    let cm;
    while ((cm = cRe.exec(rm[1]))) {
      const attrs = cm[1]; const inner = cm[2] || '';
      const refM = /r="([A-Z]+\d+)"/.exec(attrs);
      const idx = refM ? colToIdx(refM[1]) : cells.length;
      const tM = /t="([^"]+)"/.exec(attrs);
      const type = tM ? tM[1] : 'n';
      let val = '';
      const vM = /<v>([\s\S]*?)<\/v>/.exec(inner);
      if (type === 's' && vM) val = shared[+vM[1]] || '';
      else if (type === 'inlineStr') { const isM = /<t[^>]*>([\s\S]*?)<\/t>/.exec(inner); val = isM ? decodeXml(isM[1]) : ''; }
      else if (vM) val = decodeXml(vM[1]);
      cells[idx] = val;
    }
    for (let i = 0; i < cells.length; i++) if (cells[i] === undefined) cells[i] = '';
    rows.push(cells);
  }
  return rows;
}

function peek(file, maxRows) {
  const buf = fs.readFileSync(path.join(ROOT, file));
  const entries = readZipEntries(buf);
  const shared = parseSharedStrings(entries['xl/sharedStrings.xml'] ? entries['xl/sharedStrings.xml'].toString('utf8') : '');
  // achar primeira worksheet
  const sheetName = Object.keys(entries).filter(k => /^xl\/worksheets\/sheet\d+\.xml$/.test(k)).sort()[0];
  const rows = parseSheet(entries[sheetName].toString('utf8'), shared, maxRows);
  return rows;
}

const files = process.argv.slice(2);
const list = files.length ? files : ['SA1010.xlsx','SB1010.xlsx','SBM010.xlsx','CC2010.xlsx','SA3010.xlsx'];
for (const f of list) {
  console.log('='.repeat(72));
  console.log(f);
  try {
    const rows = peek(f, 3);
    rows.forEach((r, i) => console.log(`  row${i} (${r.length} cols): ` + JSON.stringify(r.slice(0, 40))));
  } catch (e) { console.log('  ERRO: ' + e.message); }
}
