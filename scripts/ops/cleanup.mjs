// Tropami — usuwanie wskazanych (testowych) obserwacji i ich zdjęć ze Storage.
// Usuwa TYLKO obserwacje wymienione w ops/cleanup.request.json (sighting_ids)
// oraz pliki w folderach ich autorów w kubełku „photos”. Bez listy nic nie robi.
import { readFileSync, appendFileSync } from 'node:fs';
const { SUPABASE_URL: U, SUPABASE_SERVICE_ROLE_KEY: K, GITHUB_STEP_SUMMARY: SUM } = process.env;
const req = JSON.parse(readFileSync(process.argv[2] || 'ops/cleanup.request.json', 'utf8'));
const ids = (req.sighting_ids || []).filter(x => /^[0-9a-f-]{36}$/i.test(x));
const DRY = req.dry_run === true;
const H = { apikey:K, Authorization:`Bearer ${K}`, 'Content-Type':'application/json' };
const log = [];
const say = s => { console.log(s); log.push(s); };
async function call(method, path, body, extra = {}){
  const r = await fetch(U + path, { method, headers:{ ...H, ...extra }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  if(!r.ok) throw new Error(`${method} ${path.slice(0, 80)} → ${r.status} ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}
if(!U || !K){ console.log('::error::Brak SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY'); process.exit(1); }
if(!ids.length){ say('Brak sighting_ids — nic do zrobienia.'); process.exit(0); }

async function main(){
const inList = `(${ids.join(',')})`;
const rows = await call('GET', `/rest/v1/sightings?id=in.${inList}&select=id,photo_url,created_by`);
say(`Obserwacje do usunięcia: ${rows.length} z ${ids.length} podanych`);
const authors = [...new Set(rows.map(r => r.created_by).filter(Boolean))];
const files = new Set();
for(const r of rows){
  const m = /\/object\/public\/photos\/(.+)$/.exec(r.photo_url || '');
  if(m) files.add(decodeURIComponent(m[1].split('?')[0]));
}
for(const a of authors){
  const list = await call('POST', '/storage/v1/object/list/photos', { prefix:`${a}/`, limit:1000 });
  for(const f of list || []) if(f.id) files.add(`${a}/${f.name}`);
}
say(`Pliki zdjęć do usunięcia: ${files.size}`);
if(DRY){ say('Tryb próbny — nic nie usunięto.'); }
else {
  const conf = await call('DELETE', `/rest/v1/confirmations?sighting_id=in.${inList}`, null, { Prefer:'return=representation' }).catch(e => { say('confirmations: ' + e.message); return []; });
  say(`Usunięto potwierdzeń: ${(conf || []).length}`);
  const del = await call('DELETE', `/rest/v1/sightings?id=in.${inList}`, null, { Prefer:'return=representation' });
  say(`Usunięto obserwacji: ${(del || []).length}`);
  if(files.size){
    const out = await call('DELETE', '/storage/v1/object/photos', { prefixes:[...files] });
    say(`Usunięto plików: ${(out || []).length}`);
  }
}
}
try{ await main(); }
catch(e){ say('BŁĄD: ' + e.message); console.log(`::error title=Cleanup::${String(e.message).replace(/\n/g, ' ').slice(0, 400)}`); process.exitCode = 1; }
if(SUM) appendFileSync(SUM, '### Czyszczenie danych testowych\n\n' + log.map(l => '- ' + l).join('\n') + '\n');
