// Tropami — wysyłka przypomnień push. Uruchamia GitHub Actions co godzinę (.github/workflows/push.yml).
// 1) pyta bazę (dk_push_due), komu i co wysłać — reguły są w supabase/supabase_v8_accounts.sql
// 2) wysyła: Web Push (przeglądarki, aplikacja z ekranu głównego, iPhone) albo Firebase (aplikacja Android)
// 3) zapisuje wynik (dk_push_mark): wyłącza martwe subskrypcje, liczy limity
//
// Zmienne środowiskowe (sekrety GitHub):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY            — wymagane
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT  — Web Push
//   FCM_SERVICE_ACCOUNT                                  — JSON konta usługi Firebase (Android), opcjonalnie
//   DRY_RUN=1                                            — tylko pokaż, nic nie wysyłaj
//   TEST=1                                               — próbne powiadomienie na wszystkie aktywne urządzenia (bez reguł i limitów)

import webpush from 'web-push';
import { GoogleAuth } from 'google-auth-library';

const env = process.env;
const APP_URL = env.APP_URL || 'https://jahrastababylon.github.io/kabanchik/app/';
const DRY = env.DRY_RUN === '1' || env.DRY_RUN === 'true';
const TEST = env.TEST === '1' || env.TEST === 'true';

// ---------- teksty ----------
const pl3 = (n, a, b, c) => { const x = Math.abs(n) % 100, y = x % 10; return n === 1 ? a : (y >= 2 && y <= 4 && (x < 12 || x > 14)) ? b : c; };
export const TEXT = {
  confirm: {
    pl: n => n > 1
      ? { title: `🤝 ${n} ${pl3(n, 'osoba potwierdziła', 'osoby potwierdziły', 'osób potwierdziło')} Twoje obserwacje`, body: `+${n * 5} XP już na Ciebie czeka.` }
      : { title: '🤝 Ktoś potwierdził Twoją obserwację', body: '+5 XP już na Ciebie czeka.' },
    en: n => n > 1
      ? { title: `🤝 ${n} people confirmed your sightings`, body: `+${n * 5} XP is waiting for you.` }
      : { title: '🤝 Someone confirmed your sighting', body: '+5 XP is waiting for you.' },
  },
  streak: {
    pl: n => ({ title: `🔥 Seria: ${n} ${pl3(n, 'dzień', 'dni', 'dni')} z rzędu`, body: 'Nie przerywaj jej — wystarczy jedna obserwacja dzisiaj.' }),
    en: n => ({ title: `🔥 ${n}-day streak`, body: 'Keep it going — one sighting today is enough.' }),
  },
  inactive: {
    pl: n => n > 0
      ? { title: `🦊 ${n} ${pl3(n, 'nowa obserwacja', 'nowe obserwacje', 'nowych obserwacji')} w Twojej okolicy`, body: 'Zobacz, kto pojawił się w tym tygodniu.' }
      : { title: '🐾 Dzikie zwierzęta czekają', body: 'Wyjdź na spacer i zaznacz pierwsze spotkanie w tym tygodniu.' },
    en: n => n > 0
      ? { title: `🦊 ${n} new ${n === 1 ? 'sighting' : 'sightings'} near you`, body: 'See who showed up this week.' }
      : { title: '🐾 Wildlife is waiting', body: 'Go for a walk and mark your first encounter this week.' },
  },
  test: {
    pl: () => ({ title: '🦊 Powiadomienia Tropami działają', body: 'To próbne powiadomienie. Do zobaczenia na szlaku!' }),
    en: () => ({ title: '🦊 Tropami notifications work', body: 'This is a test notification. See you on the trail!' }),
  },
  weekly: {
    pl: () => ({ title: '🏁 Nowe wyzwania tygodnia', body: 'Trzy zadania i odznaka Zadaniowiec — sprawdź, co na Ciebie czeka.' }),
    en: () => ({ title: '🏁 New weekly quests', body: 'Three quests and the Taskmaster badge — see what is waiting for you.' }),
  },
};
export function message(kind, lang, n){
  const k = TEXT[kind] || TEXT.weekly;
  const m = (k[lang] || k.en)(n || 0);
  return { ...m, url: `${APP_URL}?push=${kind}`, kind };
}

// ---------- Supabase ----------
async function rpc(name, body = {}){
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  if(!r.ok) throw new Error(`${name}: ${r.status} ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

// ---------- kanały ----------
async function sendWeb(row, msg){
  try{
    await webpush.sendNotification(
      { endpoint: row.endpoint, keys: { p256dh: row.p256dh, auth: row.auth } },
      JSON.stringify(msg),
      { TTL: 6 * 3600, urgency: 'normal', topic: msg.kind });
    return { ok: true };
  }catch(e){
    const code = e.statusCode || 0;
    return { ok: false, gone: code === 404 || code === 410, error: `${code} ${(e.body || e.message || '').toString().slice(0, 200)}` };
  }
}

let fcm = null;
async function fcmClient(){
  if(fcm) return fcm;
  const sa = JSON.parse(env.FCM_SERVICE_ACCOUNT);
  const auth = new GoogleAuth({ credentials: sa, scopes: ['https://www.googleapis.com/auth/firebase.messaging'] });
  fcm = { project: sa.project_id, client: await auth.getClient() };
  return fcm;
}
async function sendFcm(row, msg){
  try{
    const { project, client } = await fcmClient();
    const { token } = await client.getAccessToken();
    const r = await fetch(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: {
        token: row.endpoint,
        notification: { title: msg.title, body: msg.body },
        data: { url: msg.url, kind: msg.kind },
        android: { priority: 'normal', ttl: '21600s', notification: { icon: 'ic_stat_tropami', color: '#2D5843', tag: msg.kind } },
      } }),
    });
    if(r.ok) return { ok: true };
    const text = await r.text();
    return { ok: false, gone: r.status === 404 || /UNREGISTERED|INVALID_ARGUMENT/.test(text), error: `${r.status} ${text.slice(0, 200)}` };
  }catch(e){ return { ok: false, error: String(e.message || e).slice(0, 200) }; }
}

// ---------- start ----------
async function main(){
  if(!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY){
    console.log('::warning::Brak SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY — pomijam wysyłkę. Zobacz scripts/push/README.md');
    return;
  }
  const hasWeb = !!(env.VAPID_PUBLIC_KEY && env.VAPID_PRIVATE_KEY);
  const hasFcm = !!env.FCM_SERVICE_ACCOUNT;
  if(hasWeb) webpush.setVapidDetails(env.VAPID_SUBJECT || 'mailto:hello@tropami.eu', env.VAPID_PUBLIC_KEY, env.VAPID_PRIVATE_KEY);

  const due = await rpc(TEST ? 'dk_push_test' : 'dk_push_due');
  console.log(`${TEST ? 'Test — urządzeń' : 'Do wysłania'}: ${due.length} (web push: ${hasWeb ? 'tak' : 'brak kluczy'}, Firebase: ${hasFcm ? 'tak' : 'brak klucza'})`);
  const results = [], stats = {};
  for(const row of due){
    const msg = message(row.kind, row.lang, row.n);
    let res;
    if(DRY) res = { ok: true, dry: true };
    else if(row.channel === 'webpush') res = hasWeb ? await sendWeb(row, msg) : null;
    else if(row.channel === 'fcm') res = hasFcm ? await sendFcm(row, msg) : null;
    if(!res) continue;                                   // brak kluczy dla kanału — spróbujemy następnym razem
    stats[`${row.kind}/${row.channel}/${res.ok ? 'ok' : 'fail'}`] = (stats[`${row.kind}/${row.channel}/${res.ok ? 'ok' : 'fail'}`] || 0) + 1;
    if(DRY) console.log(`[dry] ${row.channel} ${row.lang} ${msg.title} — ${msg.body}`);
    results.push({ sub_id: row.sub_id, kind: row.kind, ok: res.ok, gone: !!res.gone, error: res.error || null });
  }
  // test nie liczy się do limitów — zapisujemy tylko martwe subskrypcje, żeby je wyłączyć
  const toMark = TEST ? results.filter(r => r.gone) : results;
  if(toMark.length && !DRY) await rpc('dk_push_mark', { p_results: toMark });
  console.log('Wynik:', JSON.stringify(stats));
  if(env.GITHUB_STEP_SUMMARY){
    const { appendFileSync } = await import('node:fs');
    appendFileSync(env.GITHUB_STEP_SUMMARY, `### Push ${TEST ? '(test)' : DRY ? '(próba)' : ''}\n\n${TEST ? 'Urządzeń z włączonymi powiadomieniami' : 'Do wysłania'}: ${due.length}\n\n\`\`\`\n${JSON.stringify(stats, null, 2)}\n\`\`\`\n`);
  }
}

if(import.meta.url === `file://${process.argv[1]}`) main().catch(e => { console.error(e); process.exit(1); });
