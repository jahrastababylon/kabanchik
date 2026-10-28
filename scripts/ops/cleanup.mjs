// Tropami — usuwanie zdjęć testowych kont ze Storage (kubełek „photos”).
// Usuwa TYLKO pliki w folderach, których nazwa (= id autora) zaczyna się od author_prefixes z ops/cleanup.request.json.
// Same obserwacje usuwa SQL (supabase_v11_rewards_moderation.sql, sekcja 0) — klucz service_role nie ma praw do tabel.
import { readFileSync, appendFileSync } from 'node:fs';
const { SUPABASE_URL: U, SUPABASE_SERVICE_ROLE_KEY: K, GITHUB_STEP_SUMMARY: SUM } = process.env;
const req = JSON.parse(readFileSync(process.argv[2] || 'ops/cleanup.request.json', 'utf8'));
const prefixes = (req.author_prefixes || []).filter(p => /^[0-9a-f]{4,}$/i.test(p));
const DRY = req.dry_run === true;
const H = { apikey:K, Authorization:`Bearer ${K}`, 'Content-Type':'application/json' };
const log = [];
const say = s => { console.log(s); log.push(s); };
async function call(method, path, body){
  const r = await fetch(U + path, { method, headers:H, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  if(!r.ok) throw new Error(`${method} ${path} → ${r.status} ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}
async function main(){
  if(!U || !K) throw new Error('Brak SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');
  if(!prefixes.length){ say('Brak author_prefixes — nic do zrobienia.'); return; }
  for(const bucket of req.buckets || ['photos']){
    const root = await call('POST', `/storage/v1/object/list/${bucket}`, { prefix:'', limit:1000 });
    const folders = (root || []).filter(f => !f.id).map(f => f.name);
    say(`[${bucket}] folderów w kubełku: ${folders.length}`);
    const mine = folders.filter(f => prefixes.some(p => f.toLowerCase().startsWith(p.toLowerCase())));
    const files = [];
    for(const f of mine){
      const list = await call('POST', `/storage/v1/object/list/${bucket}`, { prefix:`${f}/`, limit:1000 });
      for(const o of list || []) if(o.id) files.push(`${f}/${o.name}`);
    }
    say(`[${bucket}] foldery testowe: ${mine.map(f => f.slice(0, 8) + '…').join(', ') || '—'} · plików: ${files.length}`);
    if(DRY || !files.length) continue;
    const out = await call('DELETE', `/storage/v1/object/${bucket}`, { prefixes:files });
    say(`[${bucket}] usunięto plików: ${(out || []).length}`);
  }
  if(DRY) say('Tryb próbny — nic nie usunięto.');
}
try{ await main(); }
catch(e){ say('BŁĄD: ' + e.message); console.log(`::error title=Cleanup::${String(e.message).replace(/\n/g, ' ').slice(0, 400)}`); process.exitCode = 1; }
console.log(`::notice title=Cleanup::${log.join(' | ').slice(0, 900)}`);
if(SUM) appendFileSync(SUM, '### Czyszczenie zdjęć testowych\n\n' + log.map(l => '- ' + l).join('\n') + '\n');
