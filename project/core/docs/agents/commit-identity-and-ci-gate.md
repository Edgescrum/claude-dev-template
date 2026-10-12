# コミット identity と マージ前 CI ゲート

「エージェントがやってはいけないことをできてしまう／やっても誰も止めない」を機械で止めるための取り決め。
**このファイルが唯一の置き場所。** CLAUDE.md とエージェント定義（`.claude/agents/*.md`）からはここの節番号を参照し、
表・閾値・ジョブ名を書き写さないこと（写経は必ず片方だけ古くなる・4 章）。

## 節の索引

| 節 | 内容 |
|---|---|
| 1-1 | 正しい identity と許可リスト |
| 1-2 | なぜ identity を自分で指定してはいけないか（1-3 は欠番。参照番号を既存の運用と揃えるため） |
| 1-4 | 禁止事項 |
| 1-5 | 必須確認（commit 前 / push 前） |
| 1-6 | 回復手順 |
| 2-1 | branch protection とマージゲートの関係（`mergeable` は CI の合否ではない） |
| 2-1-1 | マージゲートの 5 つの検査と終了コード |
| 2-1-1a | 検査 3（base drift）の免除 |
| 2-1-1b | 何が毎回検証され、何が延期されるか |
| 2-1-1c | 検査 4 の docs-only 経路 |
| 2-1-2 | `--ref` に何を渡すか（bootstrap） |
| 2-2 | `gh pr checks` の終了コード / 2-2-1 `--required` / 2-2-2 push 直後の stale |
| 2-3 | exit 0 でも必須ジョブが走っていないことがある（必須ジョブの期待リスト） |
| 2-4 | skip は pass ではない |
| 2-5 | マージ後の再検証と Issue の自動起票 |
| 2-6 | マージゲートで防げること／防げないこと（限界） |
| 2-6-1 | 実装上の落とし穴 |
| 2-7 | branch protection の設定値 |
| 2-8 | Issue の自動クローズ |
| 2-9 | スタック PR の禁止 |
| 2-10 | 「その PR は dev に入ったのか」の判定 |
| 2-11 | 拡張点（コマンド宣言と追加検査） |
| 3-1 | `gh pr review` は使えない（レビューはコメント + ラベル） |
| 3-1-1 | 評決マーカー |
| 3-2 | GitHub 操作は `gh` で行う |
| 4 | このドキュメントの扱い |

コマンド例の `$REPO` は `REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)` で得る。
**スクリプトと CI はリポジトリ名をハードコードしない**（Actions では `$GITHUB_REPOSITORY`）。

---

## 1. コミット identity

### 1-1. 正しい identity

正しい identity はリポジトリの `.git/config` に設定済みで、worktree もこれを共有する。
**何もしなければ正しい identity になる。**

許可リストの唯一の置き場所は **`.github/allowed-commit-authors.txt`**。
検証は `scripts/check-commit-authors.sh`、CI では PR ゲート（`.github/workflows/pr-gate.yml`）の
`PR の全コミットの author を検証` ステップ。

**PR の全コミットを検査する理由:** squash マージ後の dev のコミットは author が正しくなるため、
問題が見えるのは feature ブランチだけ。HEAD だけ見ると途中のコミットがすり抜ける。

### 1-2. なぜ identity を自分で指定してはいけないか

実際の事故の発生源は環境変数でも設定ファイルでもなく、**エージェント自身が `git -c user.email=...` を
付けて commit したこと**だった。エージェントのコンテキストには「ユーザーの email」が渡ってくるが、
**それは Claude アカウントの email であって git の identity ではない。**
別の email のコミットは GitHub 上で別アカウント扱いになり、デプロイ連携などが拒否される。
`-c` は local config より優先されるので、設定を正しく固定しても防げない。

### 1-4. 禁止事項（絶対厳守）

**`git commit` に identity を自分で指定してはならない。**

- ❌ `git -c user.name=... -c user.email=... commit`
- ❌ `git commit --author="..."`
- ❌ `GIT_AUTHOR_EMAIL=...` / `GIT_COMMITTER_EMAIL=...` / `EMAIL=...`
- ❌ `git config --global user.email ...`（他のリポジトリを巻き込む）
- ❌ `git config --local user.email ...` を「念のため」実行する（既に正しい。触ると壊す側にしかならない）

唯一の例外: author 検証が本当に落ちるかを確かめる negative test。
その場合も**使い捨てリポジトリか使い捨てブランチに限る**（PR① の head に混ぜない）。

### 1-5. 必須確認（2 箇所）

**(a) 最初の commit の直前:**

```bash
git var GIT_AUTHOR_IDENT   # 許可リストの [authors] の identity であること
```

違っていたら **commit せずに止める**。`-c` で「直す」のは禁止（それが事故そのもの）。
止めたうえで次を採取して Issue に貼る:

```bash
env | grep -E '^(GIT_|EMAIL=)' ; git config --show-origin --get-all user.email
```

**(b) push の直前（省略禁止）:**

```bash
bash scripts/check-commit-authors.sh origin/dev HEAD; echo "exit=$?"
```

`exit=0` でなければ push しない。CI と同じスクリプトなので、ここで通れば CI でも通る。

### 1-6. 回復手順

```bash
git commit --amend --reset-author --no-edit                                   # 直近 1 件
git rebase --exec 'git commit --amend --reset-author --no-edit -q' origin/dev  # base 以降の全部
git push --force-with-lease                                                   # push 済みなら
```

`--reset-author` は author と committer の両方を現在の設定に戻す。

---

## 2. マージ前 CI ゲート

### 2-1. GitHub 側の保護とマージゲートの関係（片方では足りない）

`dev` / `staging` / `main` は branch protection で保護する（設定値は 2-7）。**それでもマージゲートは必須。**
両者は同じものを見ていない。

| | GitHub の branch protection | `scripts/merge-gate.sh` |
|---|---|---|
| 見る対象 | required に挙げたチェック（`PR ゲート`）の色と、PR 経由であること | 検査 1〜5（2-1-1）の内訳 |
| skip されたジョブ | **pass 扱いにする** | `allow-skip:` を明示したものだけ許す（2-4） |
| 走らなかったジョブ | required に挙げたものだけ検出。`paths:` 限定のジョブは挙げられない | 期待リストの存在を毎回確認（2-3） |
| base drift | 見ない | `behind_by == 0`（免除あり・2-1-1a） |
| 評決ラベル・マーカー | 見ない | `approved` ラベル + head SHA 一致のマーカー（3-1-1） |
| 必須リスト外の赤 | 見ない | 赤が 1 つでもあれば止める |

**`mergeable=MERGEABLE` は「CI が通っている」という意味ではない。** コンフリクトが無いというだけ。
`mergeable` を見てマージしてはならない。判定は `merge-gate.sh` の終了コード。

PR① は Orchestrator が自動でマージするため、ここで止めなければ人の目も入らないまま赤い変更が dev に入る。

### 2-1-1. 判定は `scripts/merge-gate.sh` に集約する

手順は守らなくても止まらない。判定をコードに落とし、**検証とマージを 1 つの不可分な操作**にする。

```bash
# ローカル（検証のみ・マージしない）
bash scripts/merge-gate.sh <PR番号>; echo "exit=$?"

# 実際にマージする（Orchestrator はこれだけを使う。`gh pr merge` を直接叩かない）
gh workflow run merge-gate.yml --repo "$REPO" --ref dev -f pr=<PR番号>
```

| exit | 意味 | アクション |
|---|---|---|
| `0` | 全ゲート通過 | マージしてよい |
| `1` | ゲート不合格 | ❌ **マージ禁止。** `changes-requested` を付けて Generator に差し戻す |
| `2` | 判定不能（API が stale・権限不足・使い方の誤り） | ⏳ 待って再実行。解消しなければ `blocked` |

**`1` と `2` はどちらもマージしない。** 違うのは差し戻し先だけ。

| # | 検査 | 塞ぐ穴 |
|---|---|---|
| 1 | PR が open / draft でない / **base が `dev`** / コンフリクトなし | 自動マージが staging・main に届く |
| 2 | head SHA を **REST と `git ls-remote` の 2 経路**で突き合わせる（不一致は exit 2） | stale な API 応答を根拠に別の SHA を検証してしまう |
| 3 | **base drift が 0**（`behind_by == 0`。免除は 2-1-1a） | マージ結果が未検証 / 最後の push より後に入ったジョブが走っていない |
| 4 | **`approved` ラベル** + **最新の評決マーカーが approved かつ sha が現在の head**。`review-ready` / `changes-requested` / `blocked` ラベルが残っていないこと（docs-only は 2-1-1c） | 未レビュー PR の自動マージ / Approve 後の push |
| 5 | 必須ジョブが**存在し・skip されておらず・決着して緑**。加えて**リスト外も含めて赤が 1 つも無い** | 走らなかったジョブ / skip の pass 扱い / リスト外の赤 |

全部通ると、ゲートは PR に `<!-- agent-merge-gate verdict=passed sha=<head> pr=<N> -->` を残し、
**squash マージしてブランチを削除**し、PR 本文の `closes #N` を代行する（2-8）。

**検査 3 が「走らなかったジョブ」を構造的に閉じる。** dev を取り込めば最新のワークフローで CI が回り直す。

#### 2-1-1a. 検査 3 の免除

`behind_by == 0` の要求は、dev に 1 件入るたびに open な PR 全部の CI 再実行を強いる（O(n²)）。
目的は「base が進むと統合後にだけ赤くなる」の防止なので、**base 側の新差分が CI の結果を動かしえない場合だけ**免除する。

| | 内容 |
|---|---|
| 判定対象 | `merge_base(base, head)..base` の差分（＝ head が取り込んでいない base の新コミット） |
| 免除できる | `docs/**`（`docs/agents/**` を除く）/ リポジトリ直下の `*.md`。**かつ変更種別が追加・変更** |
| 免除しない | `.github/**` / `scripts/**` / `.claude/**` / `docs/agents/**` / それ以外の許可リスト外すべて / **削除・改名** |
| 判定不能のとき | **必ず免除しない**（merge base 不明・API 失敗・250 コミット超・files 0 件または 300 件到達） |

- 判定は `gate_base_drift_exempt`（`scripts/lib/gate-common.sh`）が機械的に行う。申告に委ねない
- allowlist ∧ ¬denylist の 2 段。denylist だけだと知らない種類のファイルが素通りする
- 判断基準は「その検査が読むか」ではなく「**両側が個別には緑で、統合してはじめて赤くなるか**」
- **免除は「マージ結果を検証した」ではない。** 拾いきれなかったものは 2-5 が拾う

気になる場合はマージ結果を手元で確かめる（使い捨て worktree で `git merge --no-commit --no-ff origin/dev` →
`.github/gate-commands.env` のコマンドを実行 → worktree ごと捨てる）。

#### 2-1-1b. 何が毎回検証され、何が延期されるか

| 検査 | いつ走るか |
|---|---|
| PR ゲートの全ステップ（`.github/pr-gate-checks.txt` が正） | **PR への毎 push**（`pr-gate.yml` の 1 ジョブ） |
| マージ後の `always` 項目（`.github/post-merge-checks.txt` が正） | **dev への毎マージ**（merge-gate から `deep: skip` で呼ばれる） |
| マージ後の `deep` 項目（test / build など） | **1 日 1 回の `schedule`（dev）** と **staging / main への push（昇格）** |

- **skip は合格ではない。** `deep` と宣言した項目だけが、`--deferred` 付きで集計されたときに限り「延期」になる
- 昇格（staging / main への push）では必ず deep も走るので、deep 未検証のコードは昇格先に出ない
- ⚠️ `schedule` は既定ブランチ（main）のワークフローしか起動しない。main に届くまで定期実行は発火しない

#### 2-1-1c. 検査 4 の docs-only 経路

ドキュメントだけの PR には Generator / Evaluator を使わない。そのため検査 4 に docs-only の口がある。

| | 内容 |
|---|---|
| 起動条件 | PR に `docs-only` ラベル（**申告にすぎない。合否は決めない**） |
| 判定対象 | `GET /repos/{o}/{r}/pulls/{n}/files` の**全件**（`--paginate`）。リネームは新旧両方の名前 |
| 通す | **`docs/**`（拡張子不問）/ リポジトリ直下の `*.md` / `.claude/**/*.md`** |
| 通さない | `.github/**` / `scripts/**` / `src/**` / `.claude/**` のうち `*.md` 以外 / 下位ディレクトリの `*.md`（`src/README.md` 等） / それ以外すべて |
| 判定不能のとき | **docs-only と判定しない**（fail-closed）。一覧の取得失敗は exit 2 |
| 評決マーカー | 無くてよい。**ただしあるなら読む** — `approved` 以外が残っていたら止める（未解決の差し戻しを持ち越させない） |
| 緩めるのは | **検査 4 だけ。** 1・2・3・5 は一切緩めない |

- **範囲の正は実装（`gate_docs_only_allowed()`）。この表と実装がずれたら実装が正**で、ずれを見つけたら Issue を立てる
- `docs-only` の申告が実ファイルと矛盾したら、`approved` が揃っていても止める（ラベルを無意味にしないため）
- 残る危険: `CLAUDE.md` / `.claude/**/*.md` はエージェントの行動規約そのもの。安全制約を削る変更がレビュー無しで入りうる
- **`docs/` を読む CI 検査を足したら、その検査は PR ゲートで毎回走らせること。** docs-only PR は手元で検証されないため、
  走る場所が無いと dev を赤くできる
- `docs/` に「CI が実行するもの」を置いた瞬間に穴になる（拡張子不問のため）

### 2-1-2. `--ref` に何を渡すか

`gh workflow run` の `--ref` は「**どのツリーのゲートを使うか**」を決める（`merge-gate.sh` と
`.github/required-checks.txt` はそのツリーのものが使われる）。

| 状況 | `--ref` | 理由 |
|---|---|---|
| 通常（`merge-gate.yml` が dev にある） | **`dev`** | ゲートのコードを PR から独立させる |
| bootstrap（ゲートを最初に dev へ入れる PR） | **その PR のブランチ** | dev に無いと HTTP 422 で dispatch できない |

```bash
BR=$(gh pr view <PR番号> --repo "$REPO" --json headRefName -q .headRefName)
gh workflow run merge-gate.yml --repo "$REPO" --ref "$BR" -f pr=<PR番号> -f dry_run=true   # まず検証
gh workflow run merge-gate.yml --repo "$REPO" --ref "$BR" -f pr=<PR番号>                   # 通過後にマージ
```

bootstrap 中は PR 本人がゲートを書き換えられる（2-6）。レビューで `scripts/merge-gate.sh` と
`.github/required-checks.txt` の差分を必ず見ること。**dev に入ったら `--ref dev` に戻す。**

### 2-2. `gh pr checks` の終了コード

> ⚠️ **exit code はパイプに通すと失われる。** `gh pr checks ... | head` の `$?` は `head` のもの。
> 必ずパイプ無しで測るか、`out=$(...); rc=$?` の形にすること。

| exit | 意味 |
|---|---|
| `0` | `fail` が 1 つも無い（**「検証された」ではない**・2-3） |
| `1` | `fail` がある |
| `8` | `pending` がある |

判定に使うのは `merge-gate.sh` の終了コードであり、`gh pr checks` は状況確認の補助でしかない。

#### 2-2-1. `--required` で判定しない

`gh pr checks --required` が見せるのは required に挙げたチェックだけで、走らなかったジョブ・base drift・
評決・リスト外の赤は映らない。また「保護が設定されていない」と「required なジョブがまだ作られていない」が
同じ出力（`no required checks reported`・exit 1）になり、原因の切り分けにも使えない。

#### 2-2-2. push 直後の `gh pr checks` は 1 つ前のコミットの結果を返すことがある

GraphQL の rollup は push 直後に**前のコミットの緑**を返しうる。必ず現在の head に対して REST で引く:

```bash
gh api repos/$REPO/commits/<head SHA>/check-runs -q '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion)"'
gh api repos/$REPO/commits/<head SHA>/status     -q '.statuses[] | "\(.context)\t\(.state)"'   # 外部サービスはこちら
```

ゲートは両方を引いて 1 つの名前空間に統合している（`gate_fetch_checks`）。

### 2-3. exit 0 でも「必須ジョブが走っていない」ことがある

**PR の最後の push より後に dev へ入ったワークフローは、その PR では走らない。**
走らないジョブは「赤くない」のではなく「存在しない」ので、`gh pr checks` は exit 0 を返す。

そこで**必須ジョブの期待リスト `.github/required-checks.txt`** を置き、`scripts/check-required-jobs.sh` が
「存在する・skip されていない・（`--conclusive` なら）決着して緑」を検査する。

- 既定の必須ジョブは **`PR ゲート`（1 ジョブ）だけ**。中の検査はステップで、その正は `.github/pr-gate-checks.txt`
- ステップは存在確認の対象にならないので、`scripts/gate-summary.sh` が「manifest の id が欠けた / success 以外」を落とす
- **`paths:` などで条件付きで走るジョブを期待リストに入れない**（触っていない PR で必ず欠落になる）
- ジョブ名を変えたら、ワークフローの `jobs.<id>.name` と期待リストを**同じ PR で**直す
- `MISSING` は登録ラグでありうるので待つ（既定 300 秒）。`SKIPPED` / `FAILED` は即確定
- 期待リスト外のチェックでも赤ければ `--conclusive`（merge-gate の検査 5）が止める

### 2-4. skip は pass ではない

`if:` で丸ごと skip されたジョブも名前つきで一覧に出る。名前だけ突き合わせると「存在する」と判定してしまう。
**GitHub の required status checks も skip を pass 扱いする**ので、branch protection では塞がらない。

- `check-required-jobs.sh` は bucket を見て、`allow-skip:` を明示したジョブの skip だけ許す
- `gate-summary.sh` はステップの `skipped` を既定で失敗にする（`deep` + `--deferred` のときだけ延期）
- **コマンド未設定**（`.github/gate-commands.env` で空文字）は失敗にしないが、**pass とも書かない**。
  集計表に「SKIPPED（未設定・未検証）」、ログに `::warning::` が必ず出る（2-11）
- `skipping` / `cancelled` は `gh pr checks` の exit code に影響しない。exit 0 だけを見て「全部緑」と言わない

### 2-5. マージ後の再検証（`.github/workflows/post-merge-verify.yml`）

マージゲートは迂回できる（2-6）。防げないなら即座に気づけるようにする。

- `dev` / `staging` / `main` への push、merge-gate からの呼び出し、1 日 1 回の schedule で、
  ブランチの HEAD に対して `.github/post-merge-checks.txt` の全項目を走らせ直す
- **赤ければ Issue を自動起票する**（`scripts/report-ci-failure.sh`。同じ表題の未解決 Issue があればコメントを足す）
- **ゲートを通していないマージを検知して別の Issue を起票する**（`scripts/check-merge-gate-bypass.sh`。
  `agent-merge-gate` マーカーの無い PR と、PR に紐づかない直接 push を検出する。このジョブ自体は落とさない）
- 迂回マージで閉じ損ねた Issue を閉じる（2-8）

**⚠️ `GITHUB_TOKEN` による push は `push` ワークフローを起動しない。** そのため `merge-gate.yml` は
マージ後に `post-merge-verify.yml` を reusable workflow として明示的に呼ぶ。外すとマージ後検証が消える。

### 2-6. マージゲートで防げること／防げないこと（限界・必ず読むこと）

**限界を書かないゲートは、あると誤解される分だけ有害。これは「事故」を防ぐ仕組みであって「悪意」は防がない。**

| | 内容 |
|---|---|
| ✅ 防げる | 赤い CI のままマージされる |
| ✅ | 必須ジョブが 1 度も走っていない PR がマージされる |
| ✅ | `if:` / ラベルで無効化されたゲートを pass と誤認する |
| ✅ | stale な API 応答を根拠に別の SHA を検証してしまう |
| ✅ | base drift があるままマージされ、マージ結果が未検証になる |
| ✅ | ラベルの付け忘れ・付け間違いで、レビュー未実施の PR が自動マージに化ける |
| ✅ | Approve の後に push されたコミットが未レビューのままマージされる |
| ✅ | 自動マージが `staging` / `main` に届く |
| ❌ 防げない | **迂回。** `gh pr merge` を直接叩けばゲートは動かない（2-5 の事後検知のみ。branch protection は `PR ゲート` が緑でない PR だけ止める） |
| ❌ | **同一アカウントによるラベル・評決マーカーの偽装。** 全エージェントが同じ GitHub アカウントの `gh` を共有しているので、GitHub 側で主体を区別することは原理的にできない。Generator が `approved` を付け、マーカーを書けば通る |
| ❌ | **CI の中身の妥当性。** ジョブが緑であることは確かめるが、意味のある検査をしているかは見ない |
| ❌ | **ゲート自身の改変。** `--ref dev` なら効きにくいが、bootstrap 中は PR 側のゲートが使われる（2-1-2）。レビューで差分を必ず見る |
| ❌ | **`blocked` の自己申告。** 証跡の**形**は検査できるが、実際に試したかは検査できない（3-1-1） |
| ❌ | **docs-only 経路で通った PR の中身。** 確かめるのは変更ファイルの範囲だけで、文章の正しさは誰も見ない（2-1-1c） |
| ❌ | **未設定のコマンド。** `gate-commands.env` で空にした検査は走らない（警告は出るが止まらない・2-11） |
| ❌ | **ジョブ名を rename する PR は `--ref dev` では通らない。** 期待リストは dev のツリー（旧名）、check-run は PR（新名）。「両方の名前を許容 → rename → 旧名を消す」の 2 PR に分ける |

**「事故と怠慢が自動マージに化けない」ことは達成できる。「悪意ある迂回を止める」ことは達成できない。**

### 2-6-1. 実装上の落とし穴（触る前に読むこと）

| # | 事象 | 対処 |
|---|---|---|
| 1 | **`workflow_dispatch` だけのワークフローは永久に dispatch できない**（一度どれかのトリガで走らないと登録されず、404） | `merge-gate.yml` / `post-merge-verify.yml` に `pull_request`（`paths:` 限定）の smoke を置いて登録の足がかりにしている。**消さないこと** |
| 1b | **`--ref` が指すツリーにワークフローが無いと HTTP 422** | 2-1-2 の bootstrap 手順。404 = 未登録 / 422 = その ref に無い |
| 2 | **ゲート自身の check-run が PR の head に付き、自分が走っていることを理由に自分が通らない** | `gate_self_job_names()` が `merge-gate.yml` から `gate` / `post-merge` のジョブ名だけを読んで除外する（`GATE_SELF_JOB_IDS`）。smoke は除外しない（除外すると死角になる） |
| 3 | **awk の `==` がロケール照合で fail-open**（macOS の awk + UTF-8 で別名の日本語ジョブ名が一致する。CI では再現しない） | `gate-common.sh` で `export LC_ALL=C` |
| 4 | **`GITHUB_TOKEN` の push は `push` ワークフローを起動しない** | merge-gate から post-merge-verify を `workflow_call` で明示的に呼ぶ（2-5） |
| 5 | **必須ジョブの登録にはラグがある** | `MISSING` を待てば解決しうる側として扱う（既定 300 秒） |

### 2-7. branch protection

`dev` / `staging` / `main` の 3 ブランチに**同じ**保護をかける。
**期待値の正は `.github/branch-protection.json`**（機械可読）。ここはその要約と理由。

| 設定 | 値 | なぜ |
|---|---|---|
| required status checks | **`PR ゲート` だけ** | `paths:` 無しで毎回走る唯一のジョブ。条件付きジョブを必須にすると触っていない PR で永久 pending になる |
| `strict`（最新の base を要求） | `false` | 全 PR に無条件で追随を強いる（O(n²)）。base drift はマージゲートが免除条件つきで見る |
| 必要な approve 数 | `0` | 同一アカウントの self-review は成立しない。1 以上だと誰もマージできない。承認の証跡はラベル + マーカー |
| `enforce_admins` | `true` | 全エージェントが admin 権限のアカウントを共有している。`false` だと警告が出るだけで push が通る |
| 強制 push / ブランチ削除 | 禁止 | 統合ブランチの履歴と存在を守る |
| linear history / 会話解決 / 署名 / ロック | すべて `false` | 昇格 PR の merge commit を許す / review スレッドを使わない / 署名を運用しない |

これで機械的に強制されること: 3 ブランチへの直接 push 不可 / `PR ゲート` が緑でない PR はマージ不可 /
強制 push とブランチ削除不可。

**これでも直らないもの（マージゲートを外せない理由）:** skip の pass 扱い / 走らなかったジョブ /
base drift / 承認の証跡 / 必須リスト外の赤（2-1 の表）。**`gh pr merge` を直接叩いてよい理由にはならない。**

- ⚠️ `git push --dry-run` は保護の検証に使えない（サーバ側の判定まで届かず成功に見える）。使い捨てブランチで実際に push する
- ⚠️ GitHub Actions の `permissions:` に `administration` は書けない（ワークフローが不正になり `PR ゲート` が起動しなくなる）。
  保護設定の読み取りには admin の `gh` か PAT が要る。突き合わせ手順は manifest の `_readme`
- 緊急時に保護を外すのは**ユーザー専権**。エージェントは実行しない。外したら必ず戻す

### 2-8. Issue の自動クローズ

**`closes #N` は PR 本文に書いても閉じない。** GitHub の自動クローズは既定ブランチ（main）への
マージでしか発火せず、PR① の base は `dev` だから。`scripts/close-linked-issues.mjs` が代行する。

| 経路 | 起動 | 何を拾うか |
|---|---|---|
| `merge-gate.yml` の `gate` ジョブ | `--pr <番号>`（マージ直後） | 正規のマージ全部（主経路） |
| `post-merge-verify.yml` の `close-issues` ジョブ | `--push-range <before>..<after>`（dev への push） | `gh pr merge` 直叩き・UI からのマージ |

- 両方に置いてスクリプト側をべき等にしてある（片方だけだと正規経路か迂回経路が漏れる）
- merge-gate 側のステップは `continue-on-error: true`（クローズの失敗でマージ後検証を巻き添えにしない）
- **読むのは PR 本文だけ。** コミットメッセージは読まない

閉じる: 公式の 9 キーワード（`close(s/d)` / `fix(es/ed)` / `resolve(s/d)`）＋ `#N` または同一リポジトリの
`owner/repo#N`。大文字小文字不問・コロン可。**キーワードは Issue ごとに必要**（`Closes #1, #2` は #1 だけ）。

閉じない: キーワードの無い参照（`関連: #N`）/ フェンス付きコードブロック・インラインコード・引用（`>`）・
HTML コメントの中 / 他リポジトリ / PR 番号・存在しない番号 / 既に closed / base が dev 以外 / 未マージ。

**一番多い書き損じは宣言をバッククォートで囲むこと。** 閉じない判断は正しいが、誰も気づけないので、
対象 Issue が open のときだけ `::warning::`・step summary・**PR へのコメント**で知らせる。
クローズには必ず理由コメント（PR / コミット / 根拠の行）を残し、**コメント → close の順**で行う
（逆だと close 成功・コメント失敗のとき根拠が永久に残らない）。

棚卸し: `node scripts/close-linked-issues.mjs --audit`（何も閉じない。発火した宣言の閉じ忘れと、
発火しない場所に書かれた宣言の両方を報告する）。

### 2-9. スタック PR は既定で禁止

**依存しない変更は、必ず `dev` から独立にブランチを切ること。** PR を積む（前の PR のブランチを base にする）と、
squash マージ + ブランチ削除と組み合わさって必ず事故になる:

1. **親をマージすると子が勝手に閉じる**（親ブランチの削除で、子は「ベースブランチが消えた」扱いになる）
2. **squash すると子が全部コンフリクトする**（子は親の元のコミット列を持ったままなので、同じ変更が二重に見える）

どうしても積むなら、**親をマージする前に子の base を `dev` に張り替える**:

```bash
gh pr edit <子PR番号> --repo "$REPO" --base dev
```

コンフリクトしたら `git rebase --onto origin/dev <squash 前の親の先端> <子ブランチ>` で付け根を差し替え、
(a) `git diff <rebase 前の子> <子ブランチ>` が空、(b) `git diff --shortstat origin/dev...<子ブランチ>` の
行数が一致、の**両方**を確かめる。squash をやめないのは、履歴が「1 PR = 1 コミット」で読め、revert が PR 単位で効くため。

### 2-10. 「その PR の実装は dev に入ったのか」の判定

squash マージのため feature ブランチのコミットは dev の履歴に残らない。
**`git merge-base --is-ancestor` の `NOT ancestor` を「巻き戻された証拠」と読まない**（squash なら常にそうなる）。

```bash
gh pr view <PR番号> --repo "$REPO" --json state,mergedAt,mergeCommit   # ① これが唯一の答え（mergedAt が null なら未マージ）
gh pr view <PR番号> --repo "$REPO" --json comments                      # ② 取り下げの理由は本文とコメントにある
git log --oneline origin/dev -S '<識別子>' -- <パス>                     # ③ コードの所在は内容で引く（--all を付けない）
```

### 2-11. 拡張点（コマンド宣言と追加検査）

コアのワークフローはスタックに依存しない。スタック固有の部分は次の 3 か所だけで差し込む。

| 拡張点 | 置き場所 | 何を書くか |
|---|---|---|
| コマンド宣言 | **`.github/gate-commands.env`** | `INSTALL_CMD` / `LINT_CMD` / `TYPECHECK_CMD` / `TEST_CMD` / `BUILD_CMD`。ワークフローは `scripts/run-gate-command.sh <変数名>` 経由でここを読み、npm 等を直書きしない |
| ツールチェーン | `.github/actions/setup-toolchain/action.yml` | 言語ランタイムと依存キャッシュの準備（`actions/setup-node` など）。コアの既定は何もしない |
| 追加検査 | **`scripts/gate-extra.d/<id>.sh`** + **`.github/gate-extra-checks.txt`** | スタック固有の検査（DB の migration 検査など） |

**コマンド宣言の規則:**

| 値 | 挙動 |
|---|---|
| 値がある | 実行し、exit code で合否を決める |
| 空文字（`TEST_CMD=""`） | 実行しない。集計に **「SKIPPED（未設定・未検証）」** と出し、`::warning::` を出す。**pass とは書かない**が、ジョブも落とさない |
| 未定義（行が無い・typo） | **失敗**（変数名の typo で検査が黙って消えるのを防ぐ） |

`INSTALL_CMD` だけは `continue-on-error` を付けない（依存が入らなければ以降は「実行できていない」）。
`TEST_CMD` / `BUILD_CMD` は PR ゲートでは毎回、マージ後検証では `deep`（2-1-1b）。

**追加検査の規則:**

- `scripts/run-gate-extras.sh` が `scripts/gate-extra.d/*.sh` を名前順に**全部**実行し、
  `.github/gate-extra-checks.txt`（書式は `<id> <always|deep> <ラベル>`、id はファイル名から `.sh` を除いたもの）と突き合わせて
  `scripts/gate-summary.sh` で集計する。つまり**他の必須項目と同じ規則で落ちる**:
  - 期待リストにあるのにスクリプトが無い → `MISSING`（スクリプトを消すだけで検査が消えるのを防ぐ）
  - スクリプトがあるのに期待リストに無い → `UNKNOWN-ID`
  - exit 0 以外 → 失敗
- PR ゲート（`--context pr`）とマージ後検証（`--context post-merge`）の両方で走る。
  `deep` の項目は毎マージの再検証では延期される
- 受け取る環境変数: `GATE_CONTEXT` / `BASE_REF` / `HEAD_SHA` / `MERGE_REF`（PR のみ。マージ結果
  `refs/pull/N/merge`。コンフリクト中は空 — **空なら必ず失敗させる**。判定不能を緑にしない）
- 両方空なら「拡張検査なし」として通る
- `.github/**` と `scripts/**` は docs-only も base drift の免除も通らないので、拡張点の変更は常にフルレビュー・フル CI

---

## 3. レビューを GitHub 上でどう記録するか

### 3-1. `gh pr review` は自分が author の PR には使えない

全エージェントが同じ GitHub アカウントの `gh` を共有しているので、Evaluator の
`gh pr review --approve` / `--request-changes` は self-review として拒否される。
**`reviewDecision` は常に `null` になるので、マージ可否の判断に使ってはならない。**

```bash
gh pr comment <PR> --repo "$REPO" --body-file <レビュー本文>   # 本文はコメントとして記録する（評決マーカー必須・3-1-1）
gh pr edit <PR> --repo "$REPO" --remove-label review-ready --add-label changes-requested   # 不合格
gh pr edit <PR> --repo "$REPO" --remove-label review-ready --add-label approved            # 合格
```

**合否はラベルが正**（Orchestrator の状態スキャンが読むのはラベル）。マージゲートはラベルと評決マーカーの両方を要求する。

### 3-1-1. 評決マーカー

ラベルの「不在」で Approve を表すと、付け忘れ・付け損ね・誰かが外した PR と区別できない。
そこで **Evaluator はレビュー本文に次の 1 行を必ず含める**（名前は固定。プロジェクト名を埋めない）:

```
<!-- agent-review verdict=<approved|changes-requested|blocked> sha=<検証した head の 40 桁 SHA> pr=<PR番号> -->
```

- **最後に投稿されたマーカーが現在の評決**
- マージゲートは `approved` ラベルがあること・`review-ready` / `changes-requested` / `blocked` ラベルが無いこと・
  マーカーの `pr` が対象と一致すること・**`sha` が現在の head と一致すること**を要求する

`verdict=blocked` のときは証跡ブロックも必須（「試さずに諦めた」を防ぐため）:

```
<!-- agent-blocked-evidence
reason=<小文字・数字・ハイフンの理由コード>
evidence=<実際に試したことと結果>
-->
```

`reason=` 1 件と `evidence=` 1 件以上が必要。

```bash
# Orchestrator は blocked を受理する前にこれを通す。--expect blocked を必ず付ける
# （付けないと verdict=approved のマーカーでも exit 0 になる）
bash scripts/merge-gate.sh <PR番号> --verdict-only --expect blocked; echo "exit=$?"

# Evaluator が自分のマーカーの書式を検算するだけなら --expect は不要
bash scripts/merge-gate.sh <PR番号> --verdict-only; echo "exit=$?"
```

**限界（2-6 と同じ）:** マーカーもラベルも同じアカウントで誰でも書ける。潰せるのは事故であって偽装ではない。
恒久対策は Evaluator 用に別アカウントを用意することだが、別 identity が commit に混入する危険（1-2）と表裏なので、
やるなら commit identity と review identity を分離する設計を先に決めること。

### 3-2. GitHub 操作は `gh` で行う

GitHub 操作（PR・Issue・ラベル・コメント・API）はすべて Bash + `gh` で行う。
MCP の GitHub ツールは認証の有無が環境に依存し、静かに失敗することがある。

---

## 4. このドキュメントの扱い

**判断に使うもの（判定表・閾値・ジョブ名・終了コード）は、このドキュメントにしか置かない。**

| 種類 | 置き場所 | 理由 |
|---|---|---|
| 判定表・閾値・ジョブ名・終了コード | **このドキュメントだけ**（と、それを実装する scripts / manifest） | 間違えると結論が逆になる。複数箇所にあると 1 つの誤りが全部に伝播する |
| その場で打つコマンド・禁止事項・受け渡し | 各エージェント定義 | 実行すれば正誤が即座にわかる |

**この表と実装がずれたら実装が正。** ずれを見つけたら Issue を立てること。
