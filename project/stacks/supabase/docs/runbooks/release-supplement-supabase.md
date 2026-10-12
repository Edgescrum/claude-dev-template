# runbook 補足: Supabase（昇格 PR と選択リリースのマイグレーション確認）

> `docs/runbooks/release-and-hotfix.md` の R1〜R4 で `supabase/**` に差分があるときに、最初から最後まで通す。
> 対象: PR②（dev → staging）・PR③（staging → main）・`release-*` / `hotfix/*-main`。
> 前提: push: staging / main で remote にマイグレーションを適用するワークフローがある（`supabase db push --include-all`）。
> ここで失敗すると remote の DB が**途中まで適用された状態**になるので、**マージ前に**確認する。

---

## 1. 統合先に適用済みのマイグレーションを削除していないこと（最重要）

コンフリクト解決で「重複に見える」マイグレーションを消すと、remote の
`supabase_migrations.schema_migrations` にある version がローカルから消え、次の `db push` が止まる
（`Remote migration versions not found in local migrations directory`）。

- staging / main にだけ入った hotfix のマイグレーションは、dev に無くても**統合結果に残るのが正しい**
- **version を変えるリネームも、remote から見れば削除と同じ**
- dev にしか無い（未昇格の）マイグレーションのリネームは問題ない

手元で確認する:

```bash
git fetch origin staging main
# 統合先にある version のうち、マージ結果から消えたもの（空であること）
comm -23 \
  <(git ls-tree --name-only origin/staging supabase/migrations/ | sort) \
  <(git ls-tree --name-only HEAD supabase/migrations/ | sort)
```

どうしても消すなら、remote 側の履歴を先に整える（`supabase migration repair --status reverted <version>`。
本番に対しては運用者の許可を都度得る）。

## 2. `db push` は `--include-all` で実行される

version は実時刻ベースで、複数ブランチが並行するため「remote の最終より前の version を持つローカルのマイグレーション」は
**必ず発生する。** 素の `db push` はこれを拒否するので `--include-all` を使う。
**引き換えに、意図しないマイグレーションが混入していないことは、このレビューで担保する。**

```bash
git diff --name-status origin/staging...origin/dev -- supabase/migrations/
```

| 状態 | 見るポイント |
|---|---|
| 追加（A） | 破壊的な DDL（`DROP TABLE` / `DROP COLUMN` / 広い `UPDATE`）が無いか |
| 削除（D） | §1。原則あってはならない |
| リネーム（R） | version が変わっていないか（変わっていれば削除と同じ） |

## 3. version の衝突が無いこと（昇格 PR では「逆行」検査は免除される）

`scripts/gate-extra.d/supabase-migration-versions.sh` が PR ゲートで dev / staging / main と突き合わせる。

| 検査 | 昇格 PR（②/③）で |
|---|---|
| **衝突**（同じ version・別名のファイルが併存） | **動く** |
| **逆行**（新規 version が base の最大より大きいか） | **免除される**（昇格では逆行が構造的に起きるため。免除しないと昇格が永久に止まる） |

**昇格 PR で「緑」は「衝突が無かった」だけを意味する。** 逆行の実害は §4 で人が見る。

## 4. 同じ SQL オブジェクトの後勝ち

2 つのブランチが**別々のファイル**で同じ関数（・ビュー・トリガ・ポリシー）を貼り直すと:

- `git merge` はコンフリクトを出さない / `db reset` も `db push` も成功する / ビルドも単体テストも緑
- **version が大きいほうが最後に当たり、小さいほうの変更は黙って消える**

昇格では、統合先にだけ入った hotfix と dev の後続が同じ関数を触るので**構造的に起きる**。

一覧を出す（統合先の未取り込みマイグレーションと、この PR が同じ名前を定義しているもの）:

```bash
defs() { # ref と migration の一覧から「種別 名前<TAB>ファイル」を出す
  local ref="$1"; shift
  for f in "$@"; do
    git show "$ref:supabase/migrations/$f" 2>/dev/null \
      | grep -oiE 'create( or replace)? (function|(materialized )?view|(constraint )?trigger|policy) +"?[a-z0-9_."]+' \
      | tr 'A-Z' 'a-z' | sed -E 's/create( or replace)? //; s/"//g' | sed "s|\$|	$f|"
  done
}
only_in() { comm -23 <(git ls-tree --name-only "$1" supabase/migrations/ | sed 's#.*/##' | sort) \
                    <(git ls-tree --name-only "$2" supabase/migrations/ | sed 's#.*/##' | sort); }
join -t $'\t' \
  <(defs origin/staging $(only_in origin/staging HEAD) | sort) \
  <(defs HEAD $(only_in HEAD origin/staging) | sort)
```

（同一内容のファイルは片方にしか出ないので並ばない。ポリシーはテーブル名と組で読むこと。）

### 読み方（この順に見る）

1. **「消える側」に認可の行が無いか。** 認可ヘルパーの呼び出し / `RAISE EXCEPTION` / `auth.uid()` /
   `security definer` が含まれていたら、**勝つ側にも同じ担保があることを確認するまで昇格しない**
2. **勝つ側の定義に、消える側の意図が入っているか。** 両方を `git show` で並べて読む
3. **意図的な置換なら、その根拠（Issue / PR）を昇格 PR の本文に書く**（次の昇格で同じ読解をしないため）

### 適用後に remote で確認する

```sql
-- security definer の関数に search_path が固定されているか
select p.proname, p.proconfig from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosecdef order by 1;

-- 同名関数がオーバーロードで 2 つ残っていないか（PostgREST が解決できなくなる）
select proname, count(*), array_agg(pg_get_function_arguments(oid))
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' group by proname having count(*) > 1;
```

`DROP COLUMN` された列を相手ブランチの fixture が使っている、という同型の壊れ方は上の一覧では拾えない。

## 5. 昇格対象が参照する関数が remote に存在すること

`REVOKE / GRANT / COMMENT ON FUNCTION` と `DROP FUNCTION`（`IF EXISTS` なし）は、**対象が無いとその場でエラー**になる。
ローカルの `db reset` はゼロから流すので必ず通る。**remote のドリフト（手動ロールバック・手動 DROP）はここでしか見えない。**

- 昇格対象のマイグレーションが参照する関数シグネチャを抜き出し、remote で 1 件ずつ `to_regprocedure('<シグネチャ>')` が
  NULL でないことを確かめる（JOIN にまとめると NULL の行が消えて見落とす）
- **エージェントは stg / 本番に接続しない。** 確認用の SQL を作って運用者に渡し、運用者が SQL エディタで実行する
- 欠けていたら、正本のマイグレーションから remote に再作成してから昇格する。
  **リポジトリ側のマイグレーションをリネーム・削除して合わせない**（§1 の事故になる）

## 6. マージ後の確認

適用ワークフローは `supabase/migrations/**` に差分があるときだけ動く（差分の無い昇格では起動しないのが正常）。
差分がある昇格をマージしたら、適用ジョブが緑になったことを確認する。赤なら remote は途中まで適用された状態でありうるので、
**次の昇格を重ねる前に原因を解消する。**
