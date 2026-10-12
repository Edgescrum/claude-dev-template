## スタック: nextjs-vercel

Next.js（App Router）を Vercel にデプロイする。**Next.js の挙動は、インストール済みのバンドル文書
（`node_modules/next/dist/docs/`）を正とする。** 記憶の API は古いことがある。

### App Router の規則

| 規則 | なぜ |
|---|---|
| コンポーネントは既定で Server Component。`'use client'` は状態・イベント・ブラウザ API・`useEffect` が要るときだけ、**末端（リーフ）に寄せて**付ける | クライアントに送る JS と秘匿情報の露出面を最小にする |
| データ取得は Server Component で直接 `async/await`。Client Component から要るときは Route Handler（`app/api/**/route.ts`）経由 | 秘匿情報をクライアントに渡さない |
| データ変更は `'use server'` の Server Action。**中で必ず認証・認可を確かめる** | Server Action は POST で直接呼べる公開エンドポイントと同じ |
| 更新後は `revalidatePath` / `revalidateTag` でキャッシュを無効化する | 古い表示が残る |
| **利用者に見せるエラーは throw せず、戻り値で返す** | 本番ビルドでは throw したメッセージが伏せられ、利用者には汎用エラーしか出ない |
| 動的ルートの `params` / `searchParams` は `Promise` 型（`params: Promise<{ id: string }>`）として `await` する | 同期アクセスは旧版の書き方で、現行版では使えない |
| `fetch` は既定でキャッシュされない。キャッシュが要るときは `use cache` を明示する | 暗黙のキャッシュに頼らない |
| インポートは `@/*`（`./src/*`）、画像は `next/image`、フォントは `next/font` | 自動最適化 |
| 認証が要るページ・セッションを更新するレスポンスをキャッシュしない | `Set-Cookie` がキャッシュされると別の利用者のセッションが漏れる |

### 環境変数

| 規則 | なぜ |
|---|---|
| クライアントに出してよい値だけ `NEXT_PUBLIC_` を付ける。秘匿値（API キー・DB の管理キー・webhook の秘密）には付けない | `NEXT_PUBLIC_` はビルド時にバンドルへ**埋め込まれ**、誰でも読める |
| `NEXT_PUBLIC_` の値を変えたら**再デプロイ**する | ビルド時に焼き付くので、設定画面で変えただけでは反映されない |
| Vercel の **Sensitive 型の変数は書き込み専用（読み返せない）**。登録した値の控えは運用者がパスワード管理ツールに保管する | 紛失すると再発行と全環境の差し替えになる |
| 環境ごとにスコープを分ける: Production = 本番、staging ブランチ = デモ / UAT、その他の Preview = 開発。**本番の鍵を Preview に入れない** | プレビューから本番のデータ・決済・送信に触れる |
| 似た名前の鍵（stg 用 / 本番用）を取り違えていないか、**受信側で確かめる**（送信 200 では分からない） | 取り違えても両方「成功」を返す |
| 新しい変数を足したら、`.env.example`（または同等の一覧）とこの節の表を同じ PR で直す | 一覧が古いと次の環境構築で漏れる |

主要な変数（記入）:

| 変数 | 公開 | Production | staging | Preview | 用途 |
|---|---|---|---|---|---|
| | | | | | |

### Vercel Functions

- **Route Handler / Server Action の中の非同期処理は、レスポンスを返す前に必ず `await` する。**
  `promise.catch()` の fire-and-forget にしない — レスポンス後にプロセスが止められ、DB 更新や外部送信が途中で打ち切られる。
  レスポンス後に続けたい処理は、プラットフォームの「レスポンス後に実行」API（`after()` 等）を使う
- 実行時間・メモリの上限はプランで違う。長い処理は cron / キューに分ける

### デプロイと commit identity

- **commit author は Vercel チームのメンバーの GitHub アカウントでなければならない。**
  チーム外のアカウントに紐づく email の commit は、Vercel が preview デプロイを拒否する。
  squash 後の dev / main では正しくなるので、**feature ブランチの preview でしか気づけない**
- `git commit` に identity を自分で指定しない（CLAUDE.md の「コミット identity」）。push 前に author を検査する

### 開発サーバー（エージェント）

原則は `docs/agents/agent-dev-server.md`、Next.js での具体的な作法は **`docs/agents/dev-server-nextjs.md`**（唯一の置き場所）。

- **エージェントは `next dev` / `npm run dev` を直接起動しない。** `dev:start` / `dev:verify` / `dev:stop` を使う
- **計測（ミューテーション / before-after / e2e）は `measure:e2e` で回す。** 稼働中の `next dev` は変更を反映しないことがある
- 本番モードの確認は `prod:start` / `prod:verify` / `prod:stop`
- base URL は `dev:url` の出力をそのまま使う（認証 cookie のドメインとホスト名を一致させるため。書き換えない）
