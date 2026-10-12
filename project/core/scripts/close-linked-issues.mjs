#!/usr/bin/env node
/**
 * dev にマージされた PR の本文から「閉じるべき Issue」を抽出して閉じる。
 *
 *   node scripts/close-linked-issues.mjs --pr <PR番号>
 *   node scripts/close-linked-issues.mjs --push-range <before>..<after>
 *   node scripts/close-linked-issues.mjs --audit [--base dev] [--limit 300]
 *   共通: [--repo owner/repo] [--dry-run]
 *   検証専用: [--allow-unmerged]（使い捨ての PR で write 経路まで実証するため。ワークフローからは渡さない）
 *
 *   リポジトリは --repo → GH_REPO → GITHUB_REPOSITORY → `gh repo view` の順で解決する。
 *
 *   終了コード:
 *     0  正常終了（閉じた / 閉じるものが無かった）
 *     1  クローズに失敗したものがある（呼び出し側はマージを失敗させないこと）
 *     2  使い方の誤り・判定不能
 *
 * なぜ必要か: GitHub の自動クローズ（closes #N）は既定ブランチ（通常 main）へのマージでしか発火しない。
 *   PR① の base は dev なので、本文に書いても 1 件も閉じない。
 *
 * 起動点は 2 つ（片方だけでは足りない。両方から呼べるようにべき等にしてある）:
 *   (1) merge-gate.yml の gate ジョブ（--pr）… 正規のマージ経路
 *   (2) post-merge-verify.yml の close-issues ジョブ（--push-range）… 迂回マージの保険
 *   GITHUB_TOKEN による push は push ワークフローを起動しないので、(2) だけだと正規経路が漏れる。
 *
 * 限界:
 *   - インデント（4 スペース）のコードブロックは剥がさない（箇条書きの継続行と区別できない）
 *   - 引用（>）の中のキーワードは閉じない（GitHub 本体より厳しい側に意図的に倒している）
 *   - 他リポジトリの Issue は閉じない（ログには出す）
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// 1. クローズキーワード（GitHub 公式仕様に合わせる。キーワードは Issue ごとに必要）
// ---------------------------------------------------------------------------
// 長いものを先に並べる（`close` を先に置くと `closed` が割れる）。
const KEYWORDS = ["closes", "closed", "close", "fixes", "fixed", "fix", "resolves", "resolved", "resolve"];
const KW = KEYWORDS.join("|");

// ★ キーワードを要求する部分が全体の安全装置。緩めると `関連: #N` まで閉じる。
//   (?<![\w/#-]) … `unfix` / URL の途中に一致させない。`:` の有無・空白の有無は許す。
const KEYWORD_PREFIX = String.raw`(?<![\w/#-])(${KW})\b[ \t]*:?[ \t]*`;
const CLOSING_RE = new RegExp(
  KEYWORD_PREFIX + String.raw`(?:([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+))?#(\d+)\b`,
  "gi",
);
// 公式には未対応の URL 形式。閉じないが「書いたのに閉じていない」に気づけるよう記録する。
const URL_FORM_RE = new RegExp(
  KEYWORD_PREFIX + String.raw`https?://github\.com/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/issues\/(\d+)\b`,
  "gi",
);
// キーワードの無い裸の参照。絶対に閉じない。
const BARE_RE = /(?<![\w/#-])#(\d+)\b/g;

// ---------------------------------------------------------------------------
// 2. 本文の正規化（PR 本文はログ・diff・レビュー指摘の引用を大量に含む）
// ---------------------------------------------------------------------------

/** フェンス付きコードブロック（``` / ~~~）の中身を落とす。閉じられていないフェンスは末尾まで飲む。 */
export function stripFencedBlocks(text, removed) {
  const out = [];
  let fence = null;
  for (const line of text.split("\n")) {
    const m = /^[ \t]{0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence === null) {
      if (m && !(m[1][0] === "`" && m[2].includes("`"))) {
        fence = m[1];
        out.push("");
        continue;
      }
      out.push(line);
    } else {
      keep(removed, line);
      const closing = m && m[1][0] === fence[0] && m[1].length >= fence.length && m[2].trim() === "";
      if (closing) fence = null;
      out.push("");
    }
  }
  return out.join("\n");
}

/** 引用行（`>`）を落とす。 */
export function stripBlockquotes(text, removed) {
  return text
    .split("\n")
    .map((l) => (/^[ \t]{0,3}>/.test(l) ? (keep(removed, l), "") : l))
    .join("\n");
}

/** HTML コメント（評決マーカーなど）を落とす。 */
export function stripHtmlComments(text, removed) {
  return text.replace(/<!--[\s\S]*?-->/g, (m) => (keep(removed, m), " "));
}

/** インラインコードスパンを落とす。1 行に閉じる（対になっていない ` で本文の大半を飲まないため）。 */
export function stripInlineCode(text, removed) {
  return text
    .split("\n")
    .map((l) => l.replace(/(`+)[^`\n]*\1/g, (m) => (keep(removed, m), " ")))
    .join("\n");
}

function keep(removed, chunk) {
  if (removed) removed.push(chunk);
}

/** @returns {{text:string, removed:Record<string,string[]>}} removed は「閉じないが警告する」ために残す */
export function sanitizeBody(body) {
  const removed = { コードブロック: [], 引用: [], "HTML コメント": [], インラインコード: [] };
  let s = String(body ?? "").replace(/\r\n?/g, "\n");
  s = stripFencedBlocks(s, removed["コードブロック"]);
  s = stripBlockquotes(s, removed["引用"]);
  s = stripHtmlComments(s, removed["HTML コメント"]);
  s = stripInlineCode(s, removed["インラインコード"]);
  return { text: s, removed };
}

// ---------------------------------------------------------------------------
// 3. 参照の抽出
// ---------------------------------------------------------------------------

function lineAt(text, index) {
  const start = text.lastIndexOf("\n", index - 1) + 1;
  let end = text.indexOf("\n", index);
  if (end === -1) end = text.length;
  return text.slice(start, end).trim();
}

function sameRepoAs(owner, repo, target) {
  return owner.toLowerCase() === target.owner.toLowerCase() && repo.toLowerCase() === target.repo.toLowerCase();
}

/**
 * 落とした断片に残っていたクローズ宣言を拾う。
 * 一番多い書き損じは宣言をバッククォートで囲むこと。閉じない判断は正しいが、
 * 黙っていると誰も気づけないので「閉じるかどうかは変えず、可視性だけを足す」。
 */
export function findSuppressed(removed, target, alreadyLive) {
  const out = [];
  const seen = new Set();
  for (const [kind, chunks] of Object.entries(removed)) {
    for (const chunk of chunks) {
      for (const m of chunk.matchAll(CLOSING_RE)) {
        const [, keyword, owner, repo, num] = m;
        const number = Number(num);
        if (owner && !sameRepoAs(owner, repo, target)) continue;
        if (alreadyLive.has(number) || seen.has(number)) continue;
        seen.add(number);
        out.push({ number, keyword, kind, evidence: chunk.trim().slice(0, 160) });
      }
    }
  }
  return out;
}

/** @returns {{targets:Array, foreign:Array, urlForm:Array, bare:number[], suppressed:Array}} */
export function extractClosingRefs(body, target) {
  const { text, removed } = sanitizeBody(body);
  const targets = [];
  const foreign = [];
  const urlForm = [];
  const seen = new Set();
  const keyworded = new Set();

  for (const m of text.matchAll(CLOSING_RE)) {
    const [, keyword, owner, repo, num] = m;
    const number = Number(num);
    keyworded.add(number);
    const entry = {
      number,
      keyword,
      repo: owner ? `${owner}/${repo}` : `${target.owner}/${target.repo}`,
      evidence: lineAt(text, m.index),
    };
    if (owner && !sameRepoAs(owner, repo, target)) {
      foreign.push(entry);
      continue;
    }
    if (seen.has(number)) continue;
    seen.add(number);
    targets.push(entry);
  }

  for (const m of text.matchAll(URL_FORM_RE)) {
    const [, keyword, owner, repo, num] = m;
    keyworded.add(Number(num));
    urlForm.push({ number: Number(num), keyword, repo: `${owner}/${repo}`, evidence: lineAt(text, m.index) });
  }

  const suppressed = findSuppressed(removed, target, keyworded);
  const suppressedNums = new Set(suppressed.map((s) => s.number));

  const bare = [];
  for (const m of text.matchAll(BARE_RE)) {
    const n = Number(m[1]);
    // 落とした断片の中に宣言があるなら「参照しただけ」ではなく「書いたのに効いていない」。
    if (keyworded.has(n) || bare.includes(n) || suppressedNums.has(n)) continue;
    bare.push(n);
  }

  return { targets, foreign, urlForm, bare, suppressed };
}

// ---------------------------------------------------------------------------
// 4. GitHub 呼び出し（CLOSE_ISSUES_FIXTURE_DIR で差し替え可能・自己テスト用）
// ---------------------------------------------------------------------------
//   pr-<n>.json / pr-<n>-comments.json / issue-<n>.json / issue-<n>-comments.json /
//   compare.json / commit-pulls-<sha>.json。副作用は actions.log に追記される。
const FIXTURE = process.env.CLOSE_ISSUES_FIXTURE_DIR || "";

function fixtureRead(name) {
  const p = join(FIXTURE, name);
  if (!existsSync(p)) return undefined;
  return JSON.parse(readFileSync(p, "utf8"));
}

function fixtureAct(line) {
  appendFileSync(join(FIXTURE, "actions.log"), line + "\n");
}

function gh(args, { allow404 = false } = {}) {
  try {
    // stderr を捕まえる（正常系の 404 が「エラーが起きた」と誤読されないように）。
    return execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    const msg = String(e.stderr || e.message || "");
    if (allow404 && /HTTP 404|Not Found/i.test(msg)) return null;
    throw new Error(`gh ${args.join(" ")} が失敗しました: ${msg.trim()}`);
  }
}

function ghJson(args, opts) {
  const out = gh(args, opts);
  if (out === null) return null;
  return JSON.parse(out);
}

// ---------------------------------------------------------------------------
// 5. 1 件の Issue を閉じる
// ---------------------------------------------------------------------------

const MARKER = (pr, issue) => `<!-- agent-autoclose pr=${pr} issue=${issue} -->`;

function fetchIssue(repo, number) {
  if (FIXTURE) return fixtureRead(`issue-${number}.json`) ?? null;
  return ghJson(["api", `repos/${repo}/issues/${number}`], { allow404: true });
}

function fetchIssueComments(repo, number) {
  if (FIXTURE) return fixtureRead(`issue-${number}-comments.json`) ?? [];
  return ghJson(["api", "--paginate", `repos/${repo}/issues/${number}/comments?per_page=100`], { allow404: true }) ?? [];
}

function postComment(repo, number, body) {
  if (FIXTURE) return fixtureAct(`comment ${number}`);
  gh(["issue", "comment", String(number), "--repo", repo, "--body", body]);
}

function closeIssue(repo, number) {
  if (FIXTURE) return fixtureAct(`close ${number}`);
  gh(["issue", "close", String(number), "--repo", repo, "--reason", "completed"]);
}

function commentBody({ pr, prTitle, issue, base, sha, runUrl, evidence, keyword, merged }) {
  return [
    MARKER(pr, issue),
    merged
      ? `**#${pr} が \`${base}\` にマージされたため、この Issue をクローズしました。**`
      : `**#${pr} の検証実行（\`--allow-unmerged\`）によりクローズしました。**この PR はまだマージされていません。`,
    "",
    "| 項目 | 値 |",
    "|---|---|",
    `| PR | #${pr} ${prTitle ? prTitle.replace(/\|/g, "\\|") : ""} |`,
    `| マージ先 | \`${base}\` |`,
    `| マージコミット | ${sha && merged ? `\`${sha}\`` : "（未マージ）"} |`,
    `| 根拠 | \`${keyword}\` — ${evidence.replace(/\|/g, "\\|").slice(0, 200)} |`,
    runUrl ? `| 実行ログ | ${runUrl} |` : null,
    "",
    "GitHub の自動クローズは既定ブランチへのマージでしか発火しないため、",
    "`dev` へのマージでは `scripts/close-linked-issues.mjs` が代行しています。",
    "",
    "**誤クローズなら reopen してください。**その場合は PR 本文の `closes #N` を",
    "`関連: #N` に直さないと、再マージで再度閉じられます。",
  ]
    .filter((l) => l !== null)
    .join("\n");
}

/** @returns {"closed"|"already-closed"|"not-an-issue"|"not-found"|"failed"} */
function processIssue(repo, ref, ctx, log) {
  const { number } = ref;
  let issue;
  try {
    issue = fetchIssue(repo, number);
  } catch (e) {
    log(`  ✗ #${number} … 取得に失敗しました: ${e.message}`);
    return "failed";
  }
  if (!issue) {
    log(`  – #${number} … 存在しません（閉じません）`);
    return "not-found";
  }
  if (issue.pull_request) {
    log(`  – #${number} … PR です（Issue ではないので閉じません）`);
    return "not-an-issue";
  }
  if (issue.state !== "open") {
    log(`  – #${number} … 既に ${issue.state}（何もしません）`);
    return "already-closed";
  }
  if (ctx.dryRun) {
    log(`  · #${number} … 閉じます（--dry-run のため実行しません）／根拠: ${ref.evidence}`);
    return "closed";
  }

  // コメントが先。逆だと close 成功・comment 失敗のとき、次回は「既に closed」で根拠が永久に残らない。
  try {
    const already = fetchIssueComments(repo, number).some((c) =>
      String(c.body || "").includes(`agent-autoclose pr=${ctx.pr} `),
    );
    if (already) {
      log(`  · #${number} … 既に同じ PR のクローズ理由コメントがあります（重複投稿しません）`);
    } else {
      postComment(repo, number, commentBody({ ...ctx, issue: number, evidence: ref.evidence, keyword: ref.keyword }));
    }
    closeIssue(repo, number);
    log(`  ✓ #${number} … クローズしました（根拠: \`${ref.keyword}\` / ${ref.evidence}）`);
    return "closed";
  } catch (e) {
    log(`  ✗ #${number} … クローズに失敗しました: ${e.message}`);
    return "failed";
  }
}

// ---------------------------------------------------------------------------
// 6. PR 1 件を処理する
// ---------------------------------------------------------------------------

function fetchPr(repo, pr) {
  if (FIXTURE) return fixtureRead(`pr-${pr}.json`) ?? null;
  return ghJson(["api", `repos/${repo}/pulls/${pr}`], { allow404: true });
}

// 対象は PR① の base（dev）だけ。staging / main は「昇格」であって Issue の完了ではない。
const ALLOWED_BASES = new Set(["dev"]);
// 発火しない宣言の状態確認の上限（実行例を大量に含む本文で API を叩き続けないため）
const SUPPRESSED_LOOKUP_LIMIT = 30;
const SUPPRESSED_MARKER = (pr) => `<!-- agent-autoclose-suppressed pr=${pr} -->`;

function handlePr(repo, prNumber, opts) {
  const out = [];
  const log = (s) => out.push(s);
  const [owner, name] = repo.split("/");
  const pr = fetchPr(repo, prNumber);
  if (!pr) {
    log(`PR #${prNumber} を取得できませんでした。`);
    return { ok: false, lines: out, closed: [] };
  }

  const base = pr.base?.ref ?? "";
  if (!ALLOWED_BASES.has(base)) {
    log(`PR #${prNumber}: base=${base} は対象外です（対象は ${[...ALLOWED_BASES].join(" / ")}）。`);
    return { ok: true, lines: out, closed: [] };
  }
  // 未マージの PR で閉じない（--pr は手でも叩けるため）。
  if (!pr.merged_at && !opts.dryRun && !opts.allowUnmerged) {
    log(`PR #${prNumber}: まだマージされていません。何もしません。`);
    return { ok: true, lines: out, closed: [] };
  }
  if (!pr.merged_at && opts.allowUnmerged) {
    log(`::warning::--allow-unmerged: 未マージの PR #${prNumber} を処理します（検証用）。`);
  }

  const { targets, foreign, urlForm, bare, suppressed } = extractClosingRefs(pr.body, { owner, repo: name });

  log(`PR #${prNumber} (base=${base}) の本文から抽出:`);
  log(
    `  キーワード付き ${targets.length} 件 / 他リポジトリ ${foreign.length} 件 / ` +
      `URL 形式 ${urlForm.length} 件 / 発火しない宣言 ${suppressed.length} 件 / キーワード無し ${bare.length} 件`,
  );
  for (const f of foreign) log(`  – ${f.repo}#${f.number} … 他リポジトリなので閉じません`);
  for (const u of urlForm) {
    log(`  – ${u.repo}#${u.number} … URL 形式は公式仕様に無いため閉じません（\`${u.keyword} #${u.number}\` と書き直すこと）`);
  }
  if (bare.length) {
    const shown = bare.slice(0, 20).map((n) => `#${n}`).join(" ");
    log(`  – キーワード無しの参照は閉じません: ${shown}` + (bare.length > 20 ? ` … 他 ${bare.length - 20} 件` : ""));
  }

  // 発火しない宣言は、まだ open な Issue に対するものだけ警告する（多すぎると本当の書き損じが埋もれる）。
  const stillOpen = [];
  for (const s of suppressed.slice(0, SUPPRESSED_LOOKUP_LIMIT)) {
    let issue = null;
    try {
      issue = fetchIssue(repo, s.number);
    } catch {
      continue; // 参考情報の取得失敗でマージ後処理を落とさない
    }
    if (issue && !issue.pull_request && issue.state === "open") stillOpen.push({ ...s, issue });
  }
  if (suppressed.length > SUPPRESSED_LOOKUP_LIMIT) {
    log(`  （発火しない宣言が ${suppressed.length} 件あり、先頭 ${SUPPRESSED_LOOKUP_LIMIT} 件だけ状態を確認しました）`);
  }
  for (const s of stillOpen) {
    log(`  ::warning::#${s.number} … \`${s.keyword} #${s.number}\` が${s.kind}の中にあるため発火しません（Issue は open のまま）`);
    log(`      該当箇所: ${s.evidence}`);
  }

  const ctx = {
    pr: prNumber,
    prTitle: pr.title,
    base,
    sha: pr.merge_commit_sha,
    merged: Boolean(pr.merged_at),
    runUrl: process.env.RUN_URL || "",
    dryRun: opts.dryRun,
  };

  const closed = [];
  let failed = 0;
  for (const ref of targets) {
    const r = processIssue(repo, ref, ctx, log);
    if (r === "closed") closed.push(ref.number);
    if (r === "failed") failed += 1;
  }

  // ゲートの実行ログは誰も読まないので、書き損じは PR にもコメントする。
  if (stillOpen.length && !ctx.dryRun) {
    try {
      notifySuppressed(repo, prNumber, stillOpen, ctx);
      log(`  PR #${prNumber} に「発火しない宣言」のコメントを投稿しました。`);
    } catch (e) {
      log(`  （PR へのコメント投稿に失敗しました: ${e.message}）`);
    }
  }

  return { ok: failed === 0, lines: out, closed, suppressedOpen: stillOpen };
}

function notifySuppressed(repo, prNumber, stillOpen, ctx) {
  const existing = FIXTURE
    ? (fixtureRead(`pr-${prNumber}-comments.json`) ?? [])
    : (ghJson(["api", "--paginate", `repos/${repo}/issues/${prNumber}/comments?per_page=100`]) ?? []);
  const marker = SUPPRESSED_MARKER(prNumber);
  const nums = stillOpen.map((s) => s.number).join(",");
  // べき等: 同じ顔ぶれに対して 2 度投稿しない。
  if (existing.some((c) => String(c.body || "").includes(`${marker}\n<!-- issues=${nums} -->`))) return;
  const body = [
    marker,
    `<!-- issues=${nums} -->`,
    "## ⚠️ クローズキーワードが発火していません",
    "",
    `この PR は \`${ctx.base}\` にマージされましたが、次の宣言は**コードブロック・引用・インラインコードの中にある**ため発火しません。`,
    "",
    "| Issue | 書かれ方 | 該当箇所 |",
    "|---|---|---|",
    ...stillOpen.map(
      (s) =>
        `| #${s.number}（open） | ${s.kind}の中の \`${s.keyword} #${s.number}\` | ` +
        `${s.evidence.replace(/\|/g, "\\|").replace(/`/g, "'")} |`,
    ),
    "",
    "**対応:** 実際に完了しているなら手で閉じること。次からは宣言を素の本文に書く（バッククォートや引用で囲まない）。",
    "参照するだけで閉じたくない場合は `関連: #N` と書く。",
    "",
    "詳細は `docs/agents/commit-identity-and-ci-gate.md` の 2-8。",
  ].join("\n");
  if (FIXTURE) return fixtureAct(`pr-comment ${prNumber}`);
  gh(["pr", "comment", String(prNumber), "--repo", repo, "--body", body]);
}

// ---------------------------------------------------------------------------
// 7. push レンジから PR を割り出す（迂回マージの保険）
// ---------------------------------------------------------------------------
// commits/{sha}/pulls は Pull requests (read) を要求する。404 を `?? []` で握り潰すと
// 「対象の PR は無かった」と区別できず無言で緑になるので、失敗は上位（exit 2）に伝える。
function prsInRange(repo, before, after) {
  const compare = FIXTURE ? fixtureRead("compare.json") : ghJson(["api", `repos/${repo}/compare/${before}...${after}`]);
  if (!compare || !Array.isArray(compare.commits)) {
    throw new Error(`compare ${before}...${after} の応答に commits がありません（権限不足か API 変更）。`);
  }
  const prs = [];
  for (const c of compare.commits) {
    const list = FIXTURE
      ? (fixtureRead(`commit-pulls-${c.sha}.json`) ?? [])
      : ghJson(["api", `repos/${repo}/commits/${c.sha}/pulls`]);
    if (!Array.isArray(list)) {
      throw new Error(`commits/${c.sha}/pulls の応答が配列ではありません（Pull requests (read) 権限を確認すること）。`);
    }
    for (const p of list) if (p.merged_at && !prs.includes(p.number)) prs.push(p.number);
  }
  return prs;
}

// ---------------------------------------------------------------------------
// 8. 遡り走査（棚卸し用・何も閉じない）
// ---------------------------------------------------------------------------
// 本番と同じパーサで走らせる（別実装だと監査と自動化が食い違う）。ただし「本番と同じ」だけだと
// パーサが落とした断片を一緒に見落とすので、発火しない宣言も必ず報告する。
function audit(repo, opts) {
  const [owner, name] = repo.split("/");
  const prs = ghJson([
    "pr", "list", "--repo", repo, "--state", "merged", "--base", opts.base,
    "--limit", String(opts.limit), "--json", "number,title,body,mergedAt",
  ]);
  console.log(`マージ済み PR ${prs.length} 件（base=${opts.base}）を走査します。`);

  const rows = [];
  const misfired = [];
  for (const pr of prs) {
    const { targets, suppressed } = extractClosingRefs(pr.body, { owner, repo: name });
    for (const ref of targets) {
      const issue = fetchIssue(repo, ref.number);
      if (!issue || issue.pull_request || issue.state !== "open") continue;
      rows.push({ pr: pr.number, prTitle: pr.title, mergedAt: pr.mergedAt, issue: ref.number });
    }
    for (const s of suppressed) {
      const issue = fetchIssue(repo, s.number);
      if (!issue || issue.pull_request) continue;
      misfired.push({ pr: pr.number, prTitle: pr.title, mergedAt: pr.mergedAt, issue: s.number, kind: s.kind, keyword: s.keyword, state: issue.state });
    }
  }

  console.log("");
  console.log(`① 発火した宣言なのに Issue が open のまま: **${rows.length} 件**`);
  if (rows.length) {
    console.log("\n| Issue | 閉じるはずだった PR | マージ日時 |\n|---|---|---|");
    for (const r of rows) console.log(`| #${r.issue} | #${r.pr} ${r.prTitle} | ${r.mergedAt} |`);
  }
  const openMisfired = misfired.filter((m) => m.state === "open");
  console.log("");
  console.log(`② 発火しない場所に書かれた宣言: **${misfired.length} 件**（うち Issue が open のもの **${openMisfired.length} 件**）`);
  if (misfired.length) {
    console.log("\n| Issue | 状態 | PR | 書かれ方 | マージ日時 |\n|---|---|---|---|---|");
    for (const m of misfired) {
      console.log(`| #${m.issue} | ${m.state === "open" ? "**OPEN**" : "closed"} | #${m.pr} ${m.prTitle} | ${m.kind}の中の \`${m.keyword}\` | ${m.mergedAt} |`);
    }
  }
  console.log("");
  console.log("**このモードは何も閉じません。** 中身を確認してから手で閉じてください:");
  console.log(`  gh issue close <番号> --repo ${repo} --reason completed --comment "..."`);
  return 0;
}

// ---------------------------------------------------------------------------
// 9. エントリポイント
// ---------------------------------------------------------------------------

function usage() {
  console.error(
    [
      "usage:",
      "  node scripts/close-linked-issues.mjs --pr <PR番号> [--repo owner/repo] [--dry-run]",
      "  node scripts/close-linked-issues.mjs --push-range <before>..<after> [--repo owner/repo] [--dry-run]",
      "  node scripts/close-linked-issues.mjs --audit [--base dev] [--limit 300] [--repo owner/repo]",
    ].join("\n"),
  );
}

function resolveRepo(explicit) {
  const r = explicit || process.env.GH_REPO || process.env.GITHUB_REPOSITORY || "";
  if (r) return r;
  if (FIXTURE) return "fixture/repo";
  try {
    return gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).trim();
  } catch {
    return "";
  }
}

function main(argv) {
  let repoArg = "";
  let pr = null;
  let range = null;
  let doAudit = false;
  let base = "dev";
  let limit = 300;
  let dryRun = false;
  let allowUnmerged = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--pr") pr = argv[++i];
    else if (a === "--push-range") range = argv[++i];
    else if (a === "--repo") repoArg = argv[++i];
    else if (a === "--audit") doAudit = true;
    else if (a === "--base") base = argv[++i];
    else if (a === "--limit") limit = Number(argv[++i]);
    else if (a === "--dry-run") dryRun = true;
    else if (a === "--allow-unmerged") allowUnmerged = true;
    else if (a === "-h" || a === "--help") {
      usage();
      return 0;
    } else {
      console.error(`unknown option: ${a}`);
      usage();
      return 2;
    }
  }

  const modes = [pr !== null, range !== null, doAudit].filter(Boolean).length;
  if (modes !== 1) {
    usage();
    return 2;
  }

  const repo = resolveRepo(repoArg);
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) {
    console.error(`リポジトリ（owner/repo）を特定できません: '${repo}'（--repo か GH_REPO を指定すること）`);
    return 2;
  }

  if (doAudit) return audit(repo, { base, limit });

  let prNumbers = [];
  if (pr !== null) {
    if (!/^\d+$/.test(String(pr))) {
      console.error(`--pr が数値ではありません: '${pr}'`);
      return 2;
    }
    prNumbers = [Number(pr)];
  } else {
    const m = /^([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})$/.exec(String(range));
    if (!m) {
      console.error(`--push-range は <before>..<after> の形で指定してください: '${range}'`);
      return 2;
    }
    if (m[1] === "0".repeat(40)) {
      console.log("push の before が 0（新規ブランチ）なので判定しません。");
      return 0;
    }
    prNumbers = prsInRange(repo, m[1], m[2]);
    if (prNumbers.length === 0) {
      console.log("この push に紐づくマージ済み PR はありません。");
      return 0;
    }
    console.log(`push レンジ ${m[1]}..${m[2]} のマージ済み PR: ${prNumbers.map((n) => `#${n}`).join(" ")}`);
  }

  let ok = true;
  const allClosed = [];
  const allSuppressed = [];
  for (const n of prNumbers) {
    const r = handlePr(repo, n, { dryRun, allowUnmerged });
    for (const l of r.lines) console.log(l);
    if (!r.ok) ok = false;
    allClosed.push(...r.closed);
    for (const s of r.suppressedOpen ?? []) allSuppressed.push({ ...s, pr: n });
  }

  console.log("");
  console.log(allClosed.length ? `クローズした Issue: ${allClosed.map((n) => `#${n}`).join(" ")}` : "クローズした Issue はありません。");
  if (allSuppressed.length) {
    console.log(`発火しなかった宣言（open のまま）: ${allSuppressed.map((s) => `#${s.number}`).join(" ")}`);
  }

  if (process.env.GITHUB_STEP_SUMMARY) {
    const parts = [
      allClosed.length
        ? `## 自動クローズ\n\n${allClosed.map((n) => `- #${n}`).join("\n")}\n`
        : "## 自動クローズ\n\n閉じるべき Issue はありませんでした。\n",
    ];
    if (allSuppressed.length) {
      parts.push(
        "\n## ⚠️ 発火しなかったクローズ宣言\n\n| Issue | PR | 書かれ方 |\n|---|---|---|\n" +
          allSuppressed.map((s) => `| #${s.number} | #${s.pr} | ${s.kind}の中の \`${s.keyword}\` |`).join("\n") +
          "\n",
      );
    }
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, parts.join(""));
  }

  if (!ok) {
    console.error("::warning::一部の Issue をクローズできませんでした（マージ自体は成功しています）。");
    return 1;
  }
  return 0;
}

// import されたときは実行しない（自己テストが関数だけを使えるように）
if (process.argv[1] && process.argv[1].endsWith("close-linked-issues.mjs")) {
  let code;
  try {
    code = main(process.argv.slice(2));
  } catch (e) {
    // 「API を見に行けなかった」を「対象が無かった」と混同しない（無言の緑を作らない）。
    console.error(`::error::判定不能です: ${e.message}`);
    code = 2;
  }
  // process.exit() は stdout がパイプのとき未出力のログを捨てるので、exitCode で自然終了させる。
  process.exitCode = code;
}
