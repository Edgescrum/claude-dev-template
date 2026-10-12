# Next.js の開発サーバーをエージェントが扱う（コマンドと実装要件）

> **この文書が唯一の置き場所。** 原則（共有の固定値を持たない・素性検査・名指しの停止・古いコードの検出）は
> `docs/agents/agent-dev-server.md` が正。ここには Next.js での**コマンドの規約名と、ラッパーが満たすべき要件**だけを書く。
> ラッパーの実装（`scripts/dev-server.sh` / `scripts/prod-server.sh` 等）はプロジェクトの初期化（`docs/bootstrap.md` 0-5）で
> 用意する（雛形に実体は無い）。

---

## 0. 結論だけ先に

```bash
cd <隔離 worktree>
npm run dev:start                   # ① 起動。自分のサーバーが応答するまで確認してから返る
BASE="$(npm run -s dev:url)"        # ② 以降のテストで使う base URL（書き換えない）
npm run dev:verify                  # ③ スモークテスト / e2e の直前に打つ
npm run measure:e2e -- e2e/foo.spec.ts -g "ケース名"   # 計測はこれ（引数はそのまま Playwright へ）
npm run dev:stop                    # ④ 片づけ（自分の PID だけを止める）
```

**`PORT=` も `--port` も通常は使わない。`lsof -ti tcp:<port> | xargs kill` を打たない。**

---

## 1. コマンドの規約名

| コマンド | 何をするか | 終了コード |
|---|---|---|
| `dev:start` | worktree から採番したポートで 1 本だけ起動し、素性を検査してから返る。**ソース指紋が前回と違えば `.next` を捨てる** | 0 = 自分のサーバーが応答 / 2 = それ以外 |
| `dev:verify` | 自分のサーバーか + **起動後にソースが動いていないか**を再確認する | 同上（ソースが動いていたら 2） |
| `dev:restart` | 止めて `.next` を捨てて立て直す。**計測の前はこれ** | 同上 |
| `measure:e2e -- <args>` | 必要なら作り直してから e2e を回し、計測中のソース変更も検査する | 0 = 緑 / 1 = 本物の赤 / 2 = 計測が成立していない |
| `dev:stop` | 自分が起動した PID だけを止める | 0 |
| `dev:url` / `dev:port` | base URL / ポート番号 | 0 |
| `dev:fingerprint` | いまのディスクのソース指紋 | 0 |
| `dev:status` | 人間向けの要約（指紋のずれの有無も出す） | 0 |
| `prod:start` / `prod:verify` / `prod:restart` / `prod:stop` / `prod:url` | 本番モード（`next build` + `next start`）の同等品。採番帯は dev と重ねない | dev と同じ |

`npm run dev`（`next dev` を前景で走らせる）は運用者向けに残す。エージェントは前景で走らせると片づけられない。

---

## 2. Next.js 固有の実装要件

| 要件 | なぜ |
|---|---|
| state（PID・起動時刻・ポート・指紋）とログは `<worktree>/.dev-server/` に置き、gitignore する | 共有パスは並走するエージェント同士で上書きし合う |
| 素性検査は「listen している PID から親をたどって、自分が起動した PID に到達するか」 | `next dev` は起動後にプロセス名を `next-server (vX.Y.Z)` に書き換えるので、コマンドラインから worktree が読めない |
| 起動ログの `EADDRINUSE` / `Failed to start server` / `Another next dev server is already running` を失敗として扱う | ログに出る失敗はここで拾う（ただし他人のサーバーが応答していることは否定できない） |
| ソース指紋の対象: `src/**`・`next.config.*`・`tsconfig.json`・`package.json`・`postcss.config.*`・`instrumentation.ts`・監視 SDK の設定・**`.env.local`** | 接続先を替えたのに立て直さない、も同じ事故 |
| `.next` を消す前に `.next/dev/lock` の PID が生きていないことを確かめる。生きていれば 1 バイトも消さずに止まる | 運用者が前景で動かしているサーバーの成果物を消すと手動テストが壊れる |
| 本番モードは listener の**実 PID** を記録する（`npm start` ラッパーの PID ではない） | ラッパーを kill しても listener が残り、次の起動が即死して前のビルドが 200 を返し続ける |
| 本番モードは **BUILD_ID** を state に記録し、`prod:verify` でディスクの BUILD_ID と比べる | 動いているのがどのビルドかを機械で確かめる |
| 本番モードでビルドし直すときは Data Cache（`.next/cache/fetch-cache`）も消す | ビルドをまたいで残り、前のデータで測ることになる |
| `prod:start` の前に自分の `dev` サーバーを止める（同じ `.next` を奪い合わない） | dev と build の並走は成果物を壊す |
| アプリ起動前に接続先の検査（DB 部品があればその `check-env`）を通す | 他人のローカル DB に繋いだまま起動しない |
| 認証付きの画面を測るための「開発用ログイン」を用意するなら、本番ビルドでは構造的に無効にし、cookie のドメインを `dev:url` のホストと一致させる | `localhost` と `127.0.0.1` では cookie が乗らない |

---

## 3. やってはいけない手順

- サーバーを動かしたまま `git checkout origin/dev -- src/...` して before を測る（CSS だけ反映された混成状態を測る）
- サーバーを動かしたままミューテーションを当てて e2e を回す（`✓ Compiled` が出ても Route Handler が読むモジュールは差し替わっていないことがある）
- 失敗した spec だけを再実行して「直った」と読む（新しいサーバーで走ったから緑になっただけかもしれない）
- `.env.local` をコピーして `next dev` を直接起動する（接続先の検査を通らず、何に繋いだかの記録が残らない）

---

## 4. 自己テスト

ラッパーには `docs/agents/quality-gates-shared.md` §1 の自己テストを付ける。最低限:

- 素性判定を恒真に書き換えた写しでは「他人のサーバーを成功と判定する」「他人のプロセスを止める」が**通ってしまう**こと
- 指紋の比較を潰した写しでは「計測中のソース変更」が**素通りする**こと
- 記録の起動時刻が食い違う PID を 1 件も kill しないこと
