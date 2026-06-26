/**
 * Tiny GTFS-CSV parser. Shared by derive-bbox.js and the feed seed loaders.
 *
 * GTFS we honour:
 *   - First non-empty line is the header
 *   - Comma-separated; double-quote escaped fields support embedded commas
 *   - Lines may end with \n or \r\n
 *   - UTF-8 BOM on the first line is stripped
 *
 * Not honoured (don't appear in real GTFS):
 *   - Multi-line quoted fields
 */

export function parseCsv(text) {
  const lines = text.split(/\r?\n/);
  let i = 0;
  while (i < lines.length && lines[i].trim().length === 0) i++;
  if (i >= lines.length) return [];
  if (lines[i].charCodeAt(0) === 0xfeff) lines[i] = lines[i].slice(1);

  const header = splitLine(lines[i]);
  const out = [];
  for (let j = i + 1; j < lines.length; j++) {
    if (lines[j].length === 0) continue;
    const cols = splitLine(lines[j]);
    const row = {};
    for (let k = 0; k < header.length; k++) row[header[k]] = cols[k] ?? '';
    out.push(row);
  }
  return out;
}

function splitLine(line) {
  const out = [];
  let cur = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"') {
      if (inQuotes && line[i + 1] === '"') { cur += '"'; i++; }
      else inQuotes = !inQuotes;
    } else if (c === ',' && !inQuotes) {
      out.push(cur); cur = '';
    } else {
      cur += c;
    }
  }
  out.push(cur);
  return out;
}
