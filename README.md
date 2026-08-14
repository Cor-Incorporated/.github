# Cor. 共通シークレット検査

このリポジトリは、組織rulesetから各リポジトリのPRへ適用する
シークレット検査を管理します。対応する管理策は
`ISM-AI-01 4.4` / `ISM-F05 No.22` です。

## ガードレールの判断基準

通常のPRで止める対象は、そのPRが新たに持ち込む検出対象です。
ベースブランチに以前から存在する検出や、PRと無関係な全履歴は、
通常の開発を止める根拠にしません。既存履歴の点検は月次監査へ分離します。

| イベント | 検査範囲 | 目的 |
|---|---|---|
| `pull_request` | PRのbase SHAから`HEAD`まで | 新規混入をmerge前に停止 |
| `merge_group` | merge groupのbase SHAから`HEAD`まで | merge queueでも同じ保護を維持 |
| `push` | push前SHAから`HEAD`まで | 複数コミットpushの見逃しを防止 |
| 新規ブランチの`push` | default branchとの分岐から`HEAD`まで | 全履歴の誤検出を避ける |
| `schedule` | 本リポジトリの全履歴 | 既存リスクの月次監査 |

`schedule`はruleset対象リポジトリを横断監査する仕組みではありません。
対象リポジトリの既存履歴は、通常PRを止めない別の監査経路で扱います。

PRのbase SHAがイベントから取得できない場合は、base branchをfetchして
`merge-base`を解決します。それもできない場合は、全履歴へ暗黙に退避せず、
範囲解決エラーとして停止します。これにより、設定不備を大量の誤検出へ
変換しません。

対象リポジトリに `.gitleaks.toml` があれば、その設定を優先します。
例外は検出値・パスを必要最小限に限定し、実際の秘密を除外しないことを
レビューしてください。ひな型は `gitleaks/.gitleaks.toml.sample` にあります。

## 変更時の反証テスト

`.github/tests/gitleaks-workflow-scenarios.sh` は、workflow内の「検査する」
ステップをそのまま抽出して、次の境界を検証します。

- fork / default branchが`dev`のPRと、fetch不足時のbase ref復元
- merge queue、複数コミットpush、push前SHA欠落、新規ブランチpush
- 月次監査だけがフルスキャンになること
- PRメタデータ欠落時に全履歴スキャンへ退避しないこと
- base側の既存検出で安全なPRを止めない陰性ケース
- PRが新たに検出対象を持ち込むと停止する陽性ケース

ローカルでは次を実行します。`gitleaks` が未導入の場合、範囲解決の検査は
実行し、実バイナリによる陽性・陰性ケースだけをskipします。CIでは固定した
gitleaksをchecksum検証後に導入するため、全ケースを実行します。

```bash
.github/tests/gitleaks-workflow-scenarios.sh
```
