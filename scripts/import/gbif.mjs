// Tropami — import prawdziwych obserwacji z otwartych danych (GBIF: głównie iNaturalist „research grade”)
// Tylko licencje CC0 i CC BY 4.0. Zachowujemy prawdziwą datę, miejsce, autora i link do źródła.
// W aplikacji takie pinezki są oznaczone jako „z otwartych danych” i nie liczą się do rankingu ani raportów.
//
// Zmienne: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, DAYS (domyślnie 60), PER_CITY (domyślnie 25), DRY_RUN=1
// Miasta priorytetowe (FOCUS) dostają 3× więcej obserwacji i promień 15 km — tam startujemy z promocją.

const env = process.env;
const DAYS = +env.DAYS || 60, PER_CITY = +env.PER_CITY || 25, DRY = env.DRY_RUN === '1' || env.DRY_RUN === 'true';
const GBIF = 'https://api.gbif.org/v1';

export const CITIES = [
  ['Kraków', 50.062, 19.937], ['Warszawa', 52.230, 21.011], ['Wrocław', 51.108, 17.038], ['Gdańsk', 54.352, 18.646],
  ['Poznań', 52.407, 16.930], ['Łódź', 51.760, 19.457], ['Katowice', 50.264, 19.023], ['Lublin', 51.246, 22.568],
  ['Berlin', 52.520, 13.405], ['München', 48.137, 11.576], ['Hamburg', 53.551, 9.993], ['Wien', 48.208, 16.373],
  ['Praha', 50.075, 14.438], ['Bratislava', 48.149, 17.107], ['Budapest', 47.498, 19.040], ['Ljubljana', 46.056, 14.506],
  ['Zagreb', 45.815, 15.982], ['Vilnius', 54.687, 25.280], ['Riga', 56.950, 24.105], ['Tallinn', 59.437, 24.754],
  ['Helsinki', 60.170, 24.938], ['Stockholm', 59.329, 18.069], ['København', 55.676, 12.568], ['Oslo', 59.914, 10.752],
  ['Amsterdam', 52.368, 4.904], ['Bruxelles', 50.850, 4.352], ['Paris', 48.857, 2.352], ['London', 51.507, -0.128],
  ['Dublin', 53.350, -6.260], ['Madrid', 40.417, -3.704], ['Barcelona', 41.385, 2.173], ['Lisboa', 38.722, -9.139],
  ['Roma', 41.903, 12.496], ['Milano', 45.464, 9.190], ['Zürich', 47.377, 8.542], ['Athína', 37.984, 23.728],
  ['Lefkosia', 35.185, 33.382], ['Lemesos', 34.707, 33.022], ['Gdynia', 54.518, 18.531],
];
// 10 miast startowych: polskie (język aplikacji, nasz rynek) + miasta znane z dzikich zwierząt w mieście
// i z aktywnymi obserwatorami przyrody: dziki w Berlinie, Barcelonie, Rzymie i Trójmieście, lisy w Londynie,
// daniele w dublińskim Phoenix Park, bobry i dziki w Warszawie, Pradze i Wrocławiu.
export const FOCUS = new Set(['Kraków','Warszawa','Gdańsk','Gdynia','Wrocław','Berlin','London','Barcelona','Roma','Praha','Dublin']);
// Aves, Mammalia, Reptilia, Amphibia
const CLASSES = [212, 359, 358, 131];
const SKIP = /^(Homo|Felis catus|Canis familiaris|Canis lupus familiaris|Bos taurus|Equus|Ovis aries|Capra hircus|Sus scrofa domesticus|Gallus gallus)\b/;

export function speciesFor(o){
  const sci = o.species || o.scientificName || '', g = o.genus || sci.split(' ')[0];
  if(sci.startsWith('Sus scrofa')) return 'Dzik';
  if(sci.startsWith('Vulpes vulpes')) return 'Lis';
  if(sci.startsWith('Capreolus capreolus')) return 'Sarna';
  if(sci.startsWith('Canis lupus')) return 'Wilk';
  if(sci.startsWith('Meles meles')) return 'Borsuk';
  if(g === 'Sciurus') return 'Wiewiórka';
  if(g === 'Erinaceus') return 'Jeż';
  if(o.classKey === 212 || o.class === 'Aves') return 'Ptak';
  return 'Inne';
}
const licenseLabel = u => /zero|cc0/i.test(u || '') ? 'CC0' : /by\/4\.0|CC_BY_4_0/i.test(u || '') ? 'CC BY 4.0' : null;

async function get(url){
  for(let i = 0; i < 3; i++){
    const r = await fetch(url, { headers:{ 'User-Agent':'Tropami/1.0 (https://tropami.com)' } });
    if(r.ok) return r.json();
    await new Promise(z => setTimeout(z, 1500 * (i + 1)));
  }
  throw new Error('GBIF ' + url);
}

const vnCache = new Map();
export async function vernacular(key, fallback){
  if(!key) return fallback;
  if(!vnCache.has(key)) vnCache.set(key, (async () => {
    try{
      const d = await get(`${GBIF}/species/${key}/vernacularNames?limit=200`);
      const pick = lang => d.results.find(v => v.language === lang)?.vernacularName;
      const n = pick('pol') || pick('eng');
      return n ? n.charAt(0).toUpperCase() + n.slice(1) : fallback;
    }catch(e){ return fallback; }
  })());
  return vnCache.get(key);
}

export async function cityRows([name, lat, lng], { days = DAYS, perCity = PER_CITY } = {}){
  const focus = FOCUS.has(name); if(focus) perCity *= 3;
  const to = new Date(), from = new Date(Date.now() - days * 864e5), d = x => x.toISOString().slice(0, 10);
  const q = new URLSearchParams({ geoDistance:`${lat},${lng},${focus ? 15 : 12}km`, eventDate:`${d(from)},${d(to)}`, hasCoordinate:'true',
    occurrenceStatus:'PRESENT', basisOfRecord:'HUMAN_OBSERVATION', limit:'300' });
  CLASSES.forEach(c => q.append('classKey', c));
  ['CC0_1_0', 'CC_BY_4_0'].forEach(l => q.append('license', l));
  const res = (await get(`${GBIF}/occurrence/search?${q}`)).results || [];
  // różnorodność: najpierw ssaki/gady/płazy, max 2 obserwacje tego samego gatunku na miasto
  const per = new Map(), rows = [];
  const sorted = res.filter(o => o.decimalLatitude && o.eventDate && !SKIP.test(o.species || o.scientificName || '') && licenseLabel(o.license))
    .sort((a, b) => (a.classKey === 212) - (b.classKey === 212) || String(b.eventDate).localeCompare(String(a.eventDate)));
  for(const o of sorted){
    const k = o.speciesKey || o.taxonKey; if((per.get(k) || 0) >= 2) continue;
    per.set(k, (per.get(k) || 0) + 1);
    const species = speciesFor(o), sci = o.species || o.scientificName;
    const fixed = ['Dzik', 'Lis', 'Sarna', 'Wilk', 'Borsuk'].includes(species);
    const ds = String(o.eventDate);
    rows.push({
      source:'gbif', source_id:`gbif:${o.key}`,
      source_url: /^https:\/\/www\.inaturalist\.org\//.test(o.references || '') ? o.references : `https://www.gbif.org/occurrence/${o.key}`,
      observer: [/^[0-9a-f]{8,}$/i.test(o.recordedBy || '') ? null : o.recordedBy, /iNaturalist/i.test(o.datasetName || '') ? 'iNaturalist' : (o.datasetName || 'GBIF')].filter(Boolean).join(' · ').slice(0, 80),
      license: licenseLabel(o.license), species,
      taxon: fixed ? null : await vernacular(o.speciesKey, sci), taxon_sci: sci,
      lat: Math.round(o.decimalLatitude * 1e4) / 1e4, lng: Math.round(o.decimalLongitude * 1e4) / 1e4,
      seen_at: ds.length > 10 ? new Date(ds.length === 16 ? ds + ':00Z' : ds).toISOString() : `${ds.slice(0, 10)}T12:00:00Z`,
      city: name,
    });
    if(rows.length >= perCity) break;
  }
  return rows;
}

async function rpc(name, body){
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, { method:'POST',
    headers:{ apikey:env.SUPABASE_SERVICE_ROLE_KEY, Authorization:`Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type':'application/json' },
    body:JSON.stringify(body) });
  const t = await r.text();
  if(!r.ok) throw new Error(`${name}: ${r.status} ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}

async function main(){
  if(!DRY && (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY)){ console.log('::error::Brak SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY'); process.exit(1); }
  const all = [], stats = {};
  for(const c of CITIES){
    try{ const rows = await cityRows(c); all.push(...rows); stats[c[0]] = rows.length; }
    catch(e){ stats[c[0]] = 'błąd'; console.warn(c[0], e.message); }
  }
  const bySp = {}; all.forEach(r => bySp[r.species] = (bySp[r.species] || 0) + 1);
  console.log('Miasta:', JSON.stringify(stats)); console.log('Gatunki:', JSON.stringify(bySp)); console.log('Razem:', all.length);
  if(DRY){ all.slice(0, 15).forEach(r => console.log(`  ${r.city} · ${r.species} · ${r.taxon || ''} (${r.taxon_sci}) · ${r.seen_at.slice(0, 10)} · ${r.observer} · ${r.license}`)); return; }
  let added = 0;
  for(let i = 0; i < all.length; i += 200) added += await rpc('dk_import_sightings', { p: all.slice(i, i + 200).map(({ city, ...r }) => r) });
  console.log('Dodano nowych:', added);
  if(env.GITHUB_STEP_SUMMARY){
    const { appendFileSync } = await import('node:fs');
    appendFileSync(env.GITHUB_STEP_SUMMARY, `### Import otwartych danych\n\nZnaleziono: ${all.length} · dodano nowych: ${added}\n\n${Object.entries(bySp).map(([k, v]) => `- ${k}: ${v}`).join('\n')}\n`);
  }
}
if(import.meta.url === `file://${process.argv[1]}`) main().catch(e => { console.error(e); console.log(`::error title=Import nieudany::${String(e.message).slice(0, 300)}`); process.exit(1); });
