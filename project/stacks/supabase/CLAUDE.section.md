## スタック: supabase

PostgreSQL（Supabase）を DB に使う。**Supabase Auth を使うかどうかは要件で決め、ここに 1 行で書く**:
（記入: 例「Supabase Auth は使わず、独自の users テーブル + Cookie セッション」）

**この部品の規則は、データアクセス経路（`docs/non-functional.md` の A2）が「(a) 公開 API + RLS」であることを前提にしている。**
(b) サーバー専用を選んだ場合は、下の「クライアントの使い分け」「RLS と service-role」を ADR に沿って書き換えること
（サーバー専用の部品はまだ雛形に無い）。

### クライアントの使い分け

| 置き場所 | 用途 | 生成 |
|---|---|---|
| `lib/supabase/client.ts` | ブラウザ / Client Component | `createBrowserClient()`（内部でシングルトン） |
| `lib/supabase/server.ts` | Server Component / Server Action / Route Handler | `await createClient()`（`createServerClient` + `cookies()`）。**リクエストごとに生成**し、グローバルに保持しない |
| `lib/supabase/proxy.ts` | middleware でのセッション更新 | `updateSession(request)` |
| `lib/supabase/admin.ts` | **システム経路だけ**（下表） | `createAdminClient()`（service-role。RLS を完全にバイパスする） |

### RLS と service-role

- **RLS は全テーブルで有効にする。** ポリシー 0 件 = 誰も読めない、を既定にする
- **service-role は下の「システム経路」でだけ使ってよい。** 認証済みのページ・Server Action での使用は禁止。
  RLS で読めないものは、**認可チェックを内蔵した SECURITY DEFINER の RPC** を作って呼ぶ

| 使ってよい（システム経路） | 使ってはいけない |
|---|---|
| cron / 外部 webhook / 通知送信 / Auth の admin 操作 / capability URL（推測不能な URL で配る資源）/ health / 運用者用の管理画面 / 監査ログ書き込み | 利用者の操作で動く Server Action・ページ・Route Handler |

- **lint の `no-restricted-imports` で機械的に強制する。** `@/lib/supabase/admin` の import を全体で禁止し、
  許可するファイルを「恒久許可」「暫定許可（削減対象）」の 2 つのリストで明示する。lint のベースラインに載せて黙らせない
- 新しい SECURITY DEFINER の RPC は `REVOKE ALL ... FROM PUBLIC` → 必要なロールだけ `GRANT` → 関数内で呼び出し元を認可。
  `search_path` を固定する。**関数の実行権は既定で opt-in**（`anon` / `authenticated` に自動で付けない）

### セッションと認証（`@supabase/ssr`）

| 規則 | なぜ |
|---|---|
| サーバー側の認証確認は `supabase.auth.getClaims()` | JWT の署名を毎回検証する |
| **`supabase.auth.getSession()` をサーバー側で使わない** | 再検証が保証されず、なりすましが通る |
| middleware では `createServerClient` の直後に `getClaims()` を呼び、**間に他のコードを挟まない** | 挟むとランダムにログアウトする |
| middleware は `supabaseResponse` をそのまま返す。新しいレスポンスを作るなら `supabaseResponse.cookies.getAll()` を全部コピーする | ブラウザとサーバーのセッションがずれる |
| 認証が要るページを ISR / CDN でキャッシュしない | セッション更新の `Set-Cookie` がキャッシュされると、**別の利用者のセッションが漏れる** |

### 公開テーブルと capability secret

- **推測不能なトークン（カレンダー購読 URL・共有リンク等）を、未認証で読めるテーブルに置かない。**
  専用テーブルに分け、RLS 有効・ポリシー 0 件・`anon` / `authenticated` への GRANT なしにする。
  取得は認可内蔵の RPC と service-role 経路だけ
- 未認証で読めるテーブルに列を足すときは「**未認証に見せてよいか**」を必ず判断し、
  **公開してよい列の allowlist（列単位の GRANT）と、それを検査する DB テストの両方**を直す
- 顧客に追加の列を見せたいとき、**ポリシーを足して解決しない**（行単位のポリシーは全列を開ける）。列を絞った RPC を足す
- **公開テーブルの上に VIEW を作らない。** VIEW は既定で作成者の権限で動き、RLS を迂回して書き込みまで通りうる
- 資源を消したらトークンは失効させ（`revoked_at`）、**行は消さない**（「存在しない」と「失効した」を区別して返すため）

### マイグレーション

- **新規は必ず `supabase migration new <name>` で作り、生成された時刻をそのまま使う。**
  `YYYYMMDD000000` のような手書きは、同じ日に別ブランチで作業すると必ず衝突する
- **version は dev / staging / main のいずれとも重複してはならない。** dev 単体では `db reset` が通るので、昇格まで気づけない
- **`migration new` は常に UTC で採番する。** 別 TZ の名前が混ざったブランチでは「base より古い新規」ができる（逆行）。
  逆行しても `db reset` は通るが、統合後に同じ関数の定義が黙って上書きされる
- 検査: PR ゲートの `scripts/gate-extra.d/supabase-migration-versions.sh` が衝突と逆行を止める。手元でも同じ:
  ```bash
  git fetch origin dev staging main
  BASE_REF=dev bash scripts/gate-extra.d/supabase-migration-versions.sh
  ```
  逆行で赤くなったら、表示された base の最大 version より大きい値を**手で**付ける
- 衝突したら「新しい version で作り直し、古いファイルを消す」。**staging / main に適用済みのファイルはリネームしない**
- **別ブランチが同じ SQL 関数を `CREATE OR REPLACE` すると、後勝ちで片方が黙って消える。** merge も `db reset` も単体テストも緑のまま。
  同じ関数に触る PR では dev を取り込んで、**両方の意図を含む定義**を base の最大より新しいマイグレーションに置く。
  一覧の出し方は `docs/runbooks/release-supplement-supabase.md` §4
- **ゼロベースで再生できること。** `CREATE OR REPLACE` で戻り値の型を変えるなら先に `DROP FUNCTION`、
  既存制約と衝突するなら `DROP CONSTRAINT IF EXISTS`
- **DB のゼロベース再生（`db:reset`）は `supabase/migrations/**` に差分がある PR でだけ必須**（`docs/verification-tiers.md` §2）
- RPC を変えるときは、列の存在・オーバーロードの重複・戻り値のキーと型定義の一致を**カタログで照会**する
  （`docs/agents/quality-gates-shared.md` §2）

### ローカル DB とエージェント

- 開発は**ローカルのスタック**（Docker）で行う。stg / 本番の DB を開発作業で直接触らない
- **`supabase` CLI を直接打たない。とくに `supabase stop` は使わない。** `--workdir` は「どの config を読むか」でしかなく、
  `config.toml` を戻した後に打つと**運用者のスタックを volume ごと消す**。起動〜片づけはラッパー（`db:*`）経由で行う。
  作法・ラッパーの要件・残る穴は **`docs/agents/isolated-db-stack.md`（唯一の置き場所）**
- 運用者のスタック（記入: project_id / ポート）に対して reset・stop・seed を実行しない
- 回収作業で除外するボリュームの接頭辞: （記入: 例 `supabase_db_<運用者の project_id>`）
- 壊したときの復旧で流す seed の順: （記入）

### リリース

`docs/runbooks/release-and-hotfix.md` の R1〜R4 で `supabase/**` に差分があるときは
**`docs/runbooks/release-supplement-supabase.md` を最初から最後まで通す。**
