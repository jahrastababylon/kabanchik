// Naprawia JSON wklejony do sekretu GitHub: base64, „inteligentne” cudzysłowy, BOM, śmieci przed/po.
// Użycie: node fix-json.mjs NAZWA_ZMIENNEJ plik_wyjściowy  → kod 0 = OK, 1 = nie da się naprawić (opis w logu, bez treści sekretu)
import { writeFileSync } from 'node:fs';
const [, , name, out] = process.argv;
let raw = (process.env[name] || '').trim();
const mask = s => s.replace(/[A-Za-z0-9]/g, 'x');
function clean(t){
  t = t.replace(/^﻿/, '').replace(/[“”„‟″]/g, '"').replace(/[‘’‚‛]/g, "'").replace(/ /g, ' ');
  const a = t.indexOf('{'), b = t.lastIndexOf('}');
  return a >= 0 && b > a ? t.slice(a, b + 1) : t;
}
let candidates = [raw];
if(!raw.startsWith('{')){ try{ candidates.unshift(Buffer.from(raw.replace(/\s+/g, ''), 'base64').toString('utf8')); }catch(e){} }
for(const c of candidates){
  try{ const j = JSON.parse(clean(c)); writeFileSync(out, JSON.stringify(j, null, 2)); console.log(`${name}: OK (${Object.keys(j).join(', ')})`); process.exit(0); }
  catch(e){ var err = e; }
}
const lines = clean(raw).split('\n');
console.log(`::warning title=${name} nie jest poprawnym JSON::${String(err.message).slice(0, 160)} — wklej zawartość pliku jeszcze raz (najlepiej jako base64, patrz supabase/SETUP_v8.md).`);
console.log(`${name}: długość ${raw.length} znaków, ${lines.length} linii. Pierwsze linie (litery/cyfry zamaskowane):`);
lines.slice(0, 4).forEach((l, i) => console.log(`  ${i + 1}: ${mask(l).slice(0, 120)}   [kody: ${[...l.slice(0, 6)].map(c => c.charCodeAt(0)).join(' ')}]`));
process.exit(1);
