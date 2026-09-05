#!/usr/bin/env node
/**
 * 営業リスト｜連絡先の抽出と品質判定
 *
 * 「BOSS_メールリストを別軸で集め直す_2軸の収集仕様」の第2章・第4章を実装したもの。
 *
 * 8/29に280件集めてメールが0件だった失敗を、構造的に潰すための部分。
 * どの取得元から来たURLでも同じように扱えるよう、入力はURLの一覧だけにしてある。
 * 楽天・ヤフー・Googleマップ・広告出稿主のどれから集めても、この先は共通。
 *
 * 使い方:
 *   node scripts/extract-contacts.mjs urls.txt > out.csv
 *   node scripts/extract-contacts.mjs urls.txt --json > out.json
 *
 * urls.txt は1行1URL。空行と # で始まる行は無視する。
 *
 * 守っていること（仕様書 第5章）:
 *   - 取得前に robots.txt を確認し、禁止されている場所は取らない
 *   - 1リクエストにつき4秒以上あける
 *   - 1媒体（ホスト）につき1日200件で停止する
 *   - 根拠が確認できない項目は推測で埋めず「未確認」と書く
 */

import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

// --- 決めごと（仕様書どおり。ここ以外に数字を散らさない）-----------------

const REQUEST_INTERVAL_MS = 4000;   // 1リクエストにつき4秒以上あける
const PER_HOST_DAILY_CAP = 200;     // 1媒体につき1日200件で停止
const FETCH_TIMEOUT_MS = 20000;
const USER_AGENT =
  'Mozilla/5.0 (compatible; BOSS-contact-extractor/1.0; +contact-research)';

// 特商法の表記・会社概要・問い合わせが置かれがちなパス。
// トップページに無い場合、この順で1件だけ追って探す。
const CONTACT_PATH_HINTS = [
  '/law', '/tokushoho', '/tokutei', '/legal',
  '/company', '/about', '/corporate',
  '/contact', '/inquiry',
];

// --- 抽出 -----------------------------------------------------------------

/**
 * メールアドレスを取り出す。
 *
 * 8/29の次に起きうる失敗は「メール0件」ではなく「誤ったアドレスに大量送信」。
 * そちらのほうが被害が大きいので、拾いすぎない側に倒してある。
 */
function extractEmails(html) {
  const found = new Set();

  // mailto: が最も確実。まずこれを取る。
  for (const m of html.matchAll(/mailto:([^"'?>\s]+)/gi)) {
    found.add(m[1]);
  }

  // 本文中の平文。画像ファイル名などを拾わないよう、TLDを絞る。
  const plain =
    /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(?:com|net|jp|co\.jp|or\.jp|ne\.jp|info|biz|org|shop|store)\b/gi;
  for (const m of html.matchAll(plain)) {
    found.add(m[0]);
  }

  return [...found]
    .map((e) => e.trim().toLowerCase().replace(/^mailto:/, ''))
    .filter(isPlausibleEmail);
}

/**
 * 明らかにアドレスでないものを落とす。
 * 抽出の正規表現が壊れたとき、ここが最後の関門になる。
 */
function isPlausibleEmail(email) {
  if (email.length > 254 || email.length < 6) return false;
  if ((email.match(/@/g) || []).length !== 1) return false;

  const [local, domain] = email.split('@');
  if (!local || !domain) return false;
  if (local.length > 64) return false;
  if (domain.startsWith('.') || domain.endsWith('.')) return false;
  if (domain.includes('..')) return false;

  // 画像・スクリプトのファイル名を拾ったとき、ここで落ちる
  if (/\.(png|jpe?g|gif|svg|webp|css|js|woff2?)$/i.test(email)) return false;

  // 実在しない見本・自動生成のアドレス
  if (/^(example|test|sample|noreply|no-reply|donotreply)@/i.test(email)) return false;
  if (/@(example|test|sample|localhost)\./i.test(email)) return false;
  if (/\.(png|jpg|gif)@/i.test(email)) return false;

  return true;
}

/** 日本の電話番号。ハイフンの有無と全角に対応する。 */
function extractPhone(html) {
  const text = toHalfWidth(stripTags(html));
  const m =
    text.match(/0\d{1,4}-\d{1,4}-\d{3,4}/) ||
    text.match(/0\d{9,10}/);
  return m ? m[0] : null;
}

/**
 * 郵便番号を手がかりに所在地を取る。番地まで完全には取れない前提。
 *
 * 特商法の表記は項目が続けて並ぶため、次の項目名まで飲み込みやすい。
 * 住所の次に来る項目名で切る。
 */
const NEXT_LABELS =
  /(電話|TEL|Tel|メール|E-?mail|代表者|責任者|営業時間|定休日|FAX|URL|送料|返品|支払)/;

function extractAddress(html) {
  const text = toHalfWidth(stripTags(html)).replace(/\s+/g, ' ');
  const m = text.match(/〒?\s*\d{3}-?\d{4}[^。|｜\n]{4,60}/);
  if (!m) return null;
  // 次の項目名が現れたら、その手前で切る
  const cut = m[0].split(NEXT_LABELS)[0];
  return cut.trim().replace(/[:：\s]+$/, '') || null;
}

/** 事業者名。特商法の表記では「販売業者」「会社名」などの直後に出る。 */
function extractCompany(html) {
  const text = toHalfWidth(stripTags(html)).replace(/\s+/g, ' ');
  const labels = [
    '販売業者', '販売事業者', '事業者名', '会社名', '商号',
    '運営会社', '運営者', '法人名',
  ];
  for (const label of labels) {
    const m = text.match(new RegExp(`${label}[\\s:：]*([^\\s|｜]{2,40})`));
    if (m) return m[1].trim();
  }
  // 見つからなければ <title> で代用する。推測ではなく、出どころが違うだけ。
  const t = html.match(/<title[^>]*>([^<]{2,80})<\/title>/i);
  return t ? t[1].trim() : null;
}

/** 提案の材料になる3点（仕様書 第2章の項目9〜11）。 */
function inspectSite(html) {
  return {
    // スマホ対応。viewport が無いページはスマホで崩れている
    mobileReady: /<meta[^>]+name=["']?viewport["']?/i.test(html),
    // 更新の手がかり。3年前で止まっていれば、それが営業の切り口になる
    latestDate: extractLatestDate(html),
  };
}

function extractLatestDate(html) {
  const text = toHalfWidth(stripTags(html));
  const dates = [...text.matchAll(/20\d{2}[.\-/年]\s?(\d{1,2})[.\-/月]/g)]
    .map((m) => m[0])
    .map(normalizeDate)
    .filter(Boolean)
    .sort();
  return dates.length ? dates[dates.length - 1] : null;
}

function normalizeDate(s) {
  const m = s.match(/(20\d{2})[.\-/年]\s?(\d{1,2})/);
  if (!m) return null;
  const month = Number(m[2]);
  if (month < 1 || month > 12) return null;
  return `${m[1]}-${String(month).padStart(2, '0')}`;
}

function stripTags(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ');
}

function toHalfWidth(s) {
  return s
    .replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[－ー―‐]/g, '-')
    .replace(/＠/g, '@');
}

// --- 取得 -----------------------------------------------------------------

const robotsCache = new Map();

/** robots.txt を見て、そのパスを取ってよいかを判定する。 */
async function isAllowed(url) {
  const u = new URL(url);
  const origin = u.origin;

  if (!robotsCache.has(origin)) {
    let rules = [];
    try {
      const res = await fetchWithTimeout(`${origin}/robots.txt`);
      if (res.ok) rules = parseRobots(await res.text());
    } catch {
      // robots.txt が取れない場合は、禁止されていないものとして扱う
    }
    robotsCache.set(origin, rules);
  }

  const path = u.pathname;
  return !robotsCache.get(origin).some((rule) => path.startsWith(rule));
}

/** すべてのロボット（User-agent: *）に対する Disallow だけを見る。 */
function parseRobots(text) {
  const disallowed = [];
  let applies = false;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/#.*$/, '').trim();
    if (!line) continue;
    const [key, ...rest] = line.split(':');
    const value = rest.join(':').trim();
    const k = key.trim().toLowerCase();
    if (k === 'user-agent') applies = value === '*';
    else if (k === 'disallow' && applies && value) disallowed.push(value);
  }
  return disallowed;
}

async function fetchWithTimeout(url) {
  const ctrl = new AbortController();
  const timer = globalThis.setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, {
      signal: ctrl.signal,
      headers: { 'User-Agent': USER_AGENT },
      redirect: 'follow',
    });
  } finally {
    globalThis.clearTimeout(timer);
  }
}

// --- 1件ぶんの処理 ---------------------------------------------------------

async function collectOne(url) {
  const row = {
    url,
    company: null,
    address: null,
    phone: null,
    email: null,
    mobileReady: null,
    latestDate: null,
    sourceUrl: null,   // どこから取ったか。これが無いと後で裏が取れない
    status: null,
    note: null,
  };

  if (!(await isAllowed(url))) {
    row.status = 'skipped';
    row.note = 'robots.txt で禁止されているため取得していない';
    return row;
  }

  let html;
  try {
    const res = await fetchWithTimeout(url);
    if (!res.ok) {
      row.status = 'failed';
      row.note = `HTTP ${res.status}`;
      return row;
    }
    html = await res.text();
    row.sourceUrl = res.url;
  } catch (err) {
    row.status = 'failed';
    row.note = String(err.message || err);
    return row;
  }

  Object.assign(row, inspectSite(html));
  row.company = extractCompany(html);
  row.address = extractAddress(html);
  row.phone = extractPhone(html);

  let emails = extractEmails(html);

  // トップページに無ければ、特商法・会社概要のページを1枚だけ追う。
  // 何枚も追うと、1件あたりの時間が跳ね上がる。
  if (emails.length === 0) {
    const next = findContactLink(html, url);
    if (next && (await isAllowed(next))) {
      await sleep(REQUEST_INTERVAL_MS);
      try {
        const res = await fetchWithTimeout(next);
        if (res.ok) {
          const sub = await res.text();
          emails = extractEmails(sub);
          if (emails.length) row.sourceUrl = res.url;
          row.company ||= extractCompany(sub);
          row.address ||= extractAddress(sub);
          row.phone ||= extractPhone(sub);
        }
      } catch {
        // 追えなければメール無しとして扱う。推測で埋めない
      }
    }
  }

  row.email = pickBestEmail(emails);
  row.status = row.email ? 'ok' : 'no-email';
  if (!row.email) {
    // 仕様書 第4章1: メールが取れなければ軸1（電話・フォーム）へ回す
    row.note = 'メール未取得。フォーム営業用へ回す';
  }
  return row;
}

/** 特商法・会社概要への内部リンクを1つ選ぶ。 */
function findContactLink(html, baseUrl) {
  const links = [...html.matchAll(/href=["']([^"']+)["']/gi)].map((m) => m[1]);
  for (const hint of CONTACT_PATH_HINTS) {
    const hit = links.find((h) => h.toLowerCase().includes(hint));
    if (hit) {
      try {
        return new URL(hit, baseUrl).href;
      } catch {
        // 壊れたURLは無視する
      }
    }
  }
  return null;
}

/**
 * 複数取れた場合に1つ選ぶ。
 * 担当者名のアドレスより、窓口のアドレスを優先する。個人宛は嫌われやすい。
 */
function pickBestEmail(emails) {
  if (!emails.length) return null;
  const priority = ['info@', 'contact@', 'support@', 'inquiry@', 'shop@'];
  for (const p of priority) {
    const hit = emails.find((e) => e.startsWith(p));
    if (hit) return hit;
  }
  return emails[0];
}

// --- 重複の判定（仕様書 第4章2）--------------------------------------------

/**
 * 電話番号か、事業者自身のドメインが一致したものを同一とみなす。
 *
 * 事業者名だけでの判定はしない。同名の別法人が存在するため、
 * 仕様書でも「1〜3のいずれかと組み合わせる」と決めている。
 *
 * 注意：入力URLのホスト名は使わない。
 * 楽天・ヤフーのようなモール型では、別々の店舗が同じホストに並ぶため、
 * ホスト名で判定すると無関係な店舗どうしを1件に潰してしまう。
 * 事業者自身のドメインは、取れたメールアドレスの側から取る。
 */
function dedupe(rows) {
  const seen = new Map();
  const kept = [];

  for (const row of rows) {
    const keys = [];
    if (row.phone) keys.push(`tel:${row.phone.replace(/-/g, '')}`);
    if (row.email) {
      const domain = row.email.split('@')[1];
      if (domain) keys.push(`dom:${domain.replace(/^www\./, '')}`);
    }

    // 手がかりが1つも無い行は、潰さずそのまま残す
    if (keys.length === 0) {
      kept.push(row);
      continue;
    }

    const dup = keys.find((k) => seen.has(k));
    if (dup) {
      // 統合の記録は専用の欄に数で持つ。note に書き足すと、
      // 3件目以降で「統合」の文言が積み重なって読めなくなる
      const target = kept[seen.get(dup)];
      target.mergedCount = (target.mergedCount || 1) + 1;
      continue;
    }
    for (const k of keys) seen.set(k, kept.length);
    kept.push({ ...row, mergedCount: 1 });
  }
  return kept;
}

// --- 品質の関門（仕様書 第4章3）--------------------------------------------

function applyQualityGate(rows) {
  return rows.map((row) => {
    const reasons = [];

    if (row.status !== 'ok') reasons.push('メール未取得');
    if (row.email && !isPlausibleEmail(row.email)) reasons.push('アドレスの形式が不正');
    if (!row.sourceUrl) reasons.push('取得元URLが記録されていない');

    // 3点が揃わないものは落とさず「保留」。手作業で埋める前提
    const missing = ['company', 'address', 'phone'].filter((k) => !row[k]);

    if (reasons.length) return { ...row, verdict: '除外', verdictNote: reasons.join('・') };
    if (missing.length) {
      return {
        ...row,
        verdict: '保留',
        verdictNote: `未確認: ${missing.join('・')}（手作業で埋める）`,
      };
    }
    return { ...row, verdict: '採用', verdictNote: '' };
  });
}

// --- 出力 -----------------------------------------------------------------

const COLUMNS = [
  ['verdict', '判定'],
  ['company', '事業者名'],
  ['email', 'メール'],
  ['phone', '電話'],
  ['address', '所在地'],
  ['url', '入力URL'],
  ['sourceUrl', '取得元URL'],
  ['mobileReady', 'スマホ対応'],
  ['latestDate', '最終更新の手がかり'],
  ['mergedCount', '統合した件数'],
  ['verdictNote', '備考'],
  ['note', '記録'],
];

function toCsv(rows) {
  const esc = (v) => {
    if (v === null || v === undefined || v === '') return '未確認';
    const s = String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const head = COLUMNS.map(([, label]) => label).join(',');
  const body = rows.map((r) => COLUMNS.map(([key]) => esc(r[key])).join(','));
  return [head, ...body].join('\n');
}

// --- 実行 -----------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  const asJson = args.includes('--json');
  const file = args.find((a) => !a.startsWith('--'));

  if (!file) {
    console.error('使い方: node scripts/extract-contacts.mjs urls.txt [--json]');
    process.exit(1);
  }

  const urls = readFileSync(file, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'));

  const perHost = new Map();
  const rows = [];

  for (const [i, url] of urls.entries()) {
    let host;
    try {
      host = new URL(url).hostname;
    } catch {
      rows.push({ url, status: 'failed', note: 'URLとして読めない', sourceUrl: null });
      continue;
    }

    const count = perHost.get(host) || 0;
    if (count >= PER_HOST_DAILY_CAP) {
      console.error(`[停止] ${host} が1日の上限 ${PER_HOST_DAILY_CAP} 件に達した`);
      continue;
    }
    perHost.set(host, count + 1);

    if (i > 0) await sleep(REQUEST_INTERVAL_MS);

    const row = await collectOne(url);
    rows.push(row);
    console.error(`[${i + 1}/${urls.length}] ${row.status.padEnd(8)} ${url}`);
  }

  const result = applyQualityGate(dedupe(rows));

  const tally = result.reduce((acc, r) => {
    acc[r.verdict] = (acc[r.verdict] || 0) + 1;
    return acc;
  }, {});
  const withEmail = result.filter((r) => r.email).length;
  const rate = urls.length ? ((withEmail / urls.length) * 100).toFixed(1) : '0.0';

  console.error('');
  console.error(`入力 ${urls.length} 件 / 重複を除いて ${result.length} 件`);
  console.error(`メール取得率 ${rate}%（${withEmail} 件）`);
  console.error(`判定: ${Object.entries(tally).map(([k, v]) => `${k} ${v}`).join(' / ')}`);
  console.error('');
  console.error('※ 送信前に、採用分から1件を目視で確認すること（仕様書 第5章5）');

  process.stdout.write(asJson ? JSON.stringify(result, null, 2) : toCsv(result));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
