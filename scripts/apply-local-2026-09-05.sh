#!/usr/bin/env bash
#
# BOSS残タスク19件の結果を、Mac側のローカルへ反映する。
#
#   1. タスク管理.md の該当19行の「行末」へ追記する（行の追加・書き換えはしない）
#   2. daily-triage ダッシュボードを再生成してデプロイする
#
# 使い方（Macのターミナルに貼るだけ）:
#   bash scripts/apply-local-2026-09-05.sh
#
# 何も壊さないよう、次のようにしてある:
#   - タスク管理.md は書き換える前にバックアップを取る
#   - すでに同じ追記がある行は飛ばす（二重に書かない）
#   - 該当行が見つからない番号は、飛ばしたことを表示する
#   - デプロイは確認を1回はさむ

set -euo pipefail

TASK_FILE="${TASK_FILE:-$HOME/Claude/40_claude/タスク管理.md}"
TRIAGE_DIR="${TRIAGE_DIR:-$HOME/Claude/work/clients/BOSS/AI活用/daily-triage}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="→ "  # 追記済みかどうかの判定に使う

echo "=== 1. タスク管理.md への追記 ==="

if [[ ! -f "$TASK_FILE" ]]; then
  echo "見つからない: $TASK_FILE"
  echo "置き場が違う場合は TASK_FILE=... を指定して実行してください。"
  echo "例) TASK_FILE=~/Claude/40_claude/タスク管理.md bash $0"
  exit 1
fi

cp "$TASK_FILE" "${TASK_FILE}.bak-${STAMP}"
echo "バックアップ: ${TASK_FILE}.bak-${STAMP}"

TASK_FILE="$TASK_FILE" MARK="$MARK" python3 - <<'PY'
import io, os, re

path = os.environ['TASK_FILE']
mark = os.environ['MARK']
lines = io.open(path, encoding='utf-8').read().split('\n')

nums = ['24','25','26','34','35','36','38','39','40','41','42','43','44',
        '45','46','47','48','49','53']

# 追記文はここに持つ（シェル側と同じ内容）
APPEND = {
 '24':'完了（2026-09-05）既存2本を確認。残るは送信のみ。送信前に共有範囲の設定が要る',
 '25':'完了（2026-09-05）型⑥の完成稿を作成。これで6つの型が揃った',
 '26':'完了（2026-09-05）ペルソナ反映版を作成。段階4向け4本を追加、LINEを月2回へ修正',
 '34':'完了（2026-09-05）Linear型の実ファイルをdesign/へ配置。営業ページへの適用も完了',
 '35':'完了（2026-09-05）2軸の収集仕様を作成。抽出スクリプトも実装・検証済み',
 '36':'完了（2026-09-05）不要判断のとおり対応なし',
 '38':'未実行（2026-09-05）楽天・ヤフーの鍵が未申請のため。抽出側は完成済み',
 '39':'完了（2026-09-05）実装計画を作成。無料枠は友だち50人で上限に当たる',
 '40':'一部完了（2026-09-05）静止画26枚ぶんのプロンプトを作成。生成は画像窓口待ち',
 '41':'完了（2026-09-05）既存1本を確認。新規作成は不要',
 '42':'完了（2026-09-05）承認済みのため完了',
 '43':'一部完了（2026-09-05）17本の判定が確定。#4は実測して不採用。#6〜8は画像窓口待ち',
 '44':'終了（2026-09-05）判断のとおり終了',
 '45':'完了（2026-09-05）テスト投稿30本を作成。投稿ボタンのみ未実行（公開禁止のため）',
 '46':'完了（2026-09-05）不要判断のとおり対応なし',
 '47':'完了（2026-09-05）投稿ネタ16本と中身を作成',
 '48':'完了（2026-09-05）3県の申請手順と候補一覧を作成。所在地の確定待ち',
 '49':'完了（2026-09-05）手順と候補一覧を作成。紹介報酬制度の有無は未確認',
 '53':'完了（2026-09-05）調査を作成。海外の型を持ち込む側が本命',
}

done, skipped, missing = [], [], []

for n in nums:
    # 行頭付近にタスク番号が出てくる行を1つだけ選ぶ
    pat = re.compile(r'^\s*[-*|\s]*(?:\[[ xX]\]\s*)?#?' + n + r'(?![0-9])')
    idx = [i for i, l in enumerate(lines) if pat.search(l)]
    if not idx:
        missing.append(n); continue
    i = idx[0]
    if '2026-09-05' in lines[i]:
        skipped.append(n); continue
    lines[i] = lines[i].rstrip() + ' ' + mark + APPEND[n]
    done.append(n)

io.open(path, 'w', encoding='utf-8').write('\n'.join(lines))

print(f'追記した: {len(done)}件 {" ".join(done) if done else "-"}')
print(f'既に追記済みで飛ばした: {len(skipped)}件 {" ".join(skipped) if skipped else "-"}')
print(f'該当行が見つからず飛ばした: {len(missing)}件 {" ".join(missing) if missing else "-"}')
if missing:
    print('※ 見つからなかった番号は、手で行末へ足してください（内容は handover-2026-09-05.md の第1章）')
PY

echo
echo "=== 2. ダッシュボードの更新 ==="

if [[ ! -d "$TRIAGE_DIR" ]]; then
  echo "見つからない: $TRIAGE_DIR"
  echo "置き場が違う場合は TRIAGE_DIR=... を指定してください。"
  exit 1
fi

cd "$TRIAGE_DIR"

echo "反映する内容を data/2026-09-05.md へ追記します。"
mkdir -p data
cat >> data/2026-09-05.md <<'EOF'

## BOSS残タスク19件（2026-09-05 こば）

- 完了16件: 24 25 26 34 35 36 39 41 42 44 45 46 47 48 49 53
- 一部完了2件（画像生成の窓口待ち）: 40 43
- 未実行1件（楽天・ヤフーの鍵待ち）: 38

進んだマイルストーン
- [MS4] デザイン指示書（Linear型）の実ファイル配置と、営業ページへの適用
- [MS5] デザイン用プロンプト17本の判定確定、海外のAI案件の調査
- [MS6] メールリスト2軸の収集仕様と、連絡先抽出スクリプトの実装

判断待ち5件
- 自社の所在地・運営者情報（48 39 49 が停止中）
- LINEのメールアドレスと返信時間帯（39）
- Googleマップの月$64を出すか（35）
- 個人アカウント30本の公開範囲（45）
- AIO資料の共有範囲の設定（24）
EOF

echo "サイトを生成します。"
python3 build_site.py

echo
read -r -p "デプロイしますか（公開されます）。よければ y: " ans
if [[ "$ans" == "y" ]]; then
  wrangler pages deploy
  echo "公開しました: https://daily-triage.pages.dev"
else
  echo "デプロイは行っていません。生成だけ済んでいます。"
fi
