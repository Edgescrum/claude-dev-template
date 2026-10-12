# セッションをまたいで溜まる残骸を回収する

> **この文書が唯一の置き場所。** CLAUDE.md やエージェントのブリーフに書き写さないこと。
> 対象: 運用者 / Orchestrator。**個々の Generator / Evaluator の片づけとは別の話。**

---

## 0. 個々の片づけとの違い

各エージェントの片づけ（自分のサーバー・DB スタックを止める）は `docs/agents/agent-dev-server.md` §0 が正で、
それ自体は効く。ここで扱うのは**それでも残るもの**:

- worktree のディレクトリ本体（`git worktree remove` は誰も打たない）
- コンテナのビルドキャッシュ / 未使用イメージ / 使われなくなった名前付きボリューム

1 セッションでは目立たず、**数十セッション分が積み上がってから**ディスクを圧迫する。
定期的に（ディスク空きが減ったら）まとめて回収する。

**原則: 「確実に不要」と判定できたものだけを消す。** 判定できないものは残して一覧で報告する。

---

## 1. マージ済み worktree の判定（罠がある）

### ❌ `git merge-base --is-ancestor` を使わない

**squash merge では、マージ済みブランチのコミットは dev の祖先にならない。**
この判定はマージ済みでも false を返し、大半を「未マージ」と誤判定する。

### ✅ 正しい判定

「remote ブランチが消えている」か「merged PR の head 名に一致する」で見る。

```bash
gh pr list --state merged --limit 1000 \
  --json headRefName --jq '.[].headRefName' | sort -u > merged.txt

# 各 worktree のブランチが merged.txt にあるか、
# あるいは refs/remotes/origin/<branch> が既に無いか
```

- `git worktree list --porcelain` の `branch` 行を使う
- detached な worktree は追跡すべきブランチが無いので削除してよい（未コミットの変更が無いことは確かめる）
- **未コミットの変更がある worktree は消さない。** 一覧に出して運用者に判断を仰ぐ

---

## 2. 削除前の安全確認（ここにも罠がある）

### ❌ `lsof` の終了コードで「使用中」を判定しない

```bash
if lsof -a -d cwd -- "$path" >/dev/null 2>&1; then ...   # 出力が空でも 0 を返すことがある
```

この判定は、どのプロセスも掴んでいない worktree を「使用中」と誤判定する。

### ✅ 出力が空でないことで判定する

```bash
out=$(lsof -a -d cwd -- "$path" 2>/dev/null | sed -n '2,$p')
[ -n "$out" ] && echo "IN USE: $path"
```

使用中なら消さない。`git worktree remove --force` が失敗する場合（`.git` が壊れている等）は、
使用中でないことを確かめてから `rm -rf` し、`git worktree prune` で登録を掃除する。

---

## 3. コンテナ資源の回収

```bash
docker builder prune -af      # ビルドキャッシュ。稼働中コンテナに影響しない
docker image prune -af        # 稼働中コンテナが使うイメージは残る
```

**名前付きボリュームは `docker volume prune -f` では消えない**（dangling 扱いにならない）。
ローカル DB スタックの多くは名前付きボリュームを作るので、名前で選んで消す。

> **運用者のローカル DB のボリュームを必ず名前で除外すること。**
> 手動テスト用のデータが入っており、消すと復元できない。
> 稼働中なら dangling にならないので通常は安全側に落ちるが、**停止中に回収をかけると消える。**
> 除外する名前は CLAUDE.md の「スタック」節（DB 部品の文書）に書いておく。

```bash
KEEP_PREFIX='<運用者のローカル DB ボリュームの接頭辞>'
docker volume ls -qf dangling=true | grep -v "^${KEEP_PREFIX}" | \
  while read -r v; do docker volume rm "$v"; done
```

---

## 4. 実行後の確認

- **運用者のローカル DB が生きていること**を必ず確かめる（代表的な行が読めること）。
  空なら CLAUDE.md の復旧手順（DB 部品の節）へ
- 回収前後の量（worktree 数・容量・ボリューム数・ディスク空き）を報告に載せる
- macOS（APFS）では削除直後の `df` に全量が反映されないことがある。実体は `du -sh` で確かめる
