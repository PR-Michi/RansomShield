# 🛡️ RansomShield

**ランサムウェア防衛ツール for Windows 10/11**

[English](#english) | [日本語](#日本語)

---

## 日本語

### 概要

RansomShield は、経済産業省・IPA が推奨するランサムウェア対策を  
**ワンクリックで適用・確認・解除** できる Windows 用セキュリティツールです。

管理者権限で起動し、CLIメニューから各防衛設定を操作します。

---

### 機能一覧（5モジュール）

| # | 機能 | 内容 |
|---|------|------|
| 1 | **CFA（コントロールドフォルダーアクセス）** | ランサムウェアによる重要フォルダへの書き込みをブロック |
| 2 | **SMB / 管理共有ブロック** | 社内ネットワーク経由の横展開を防止 |
| 3 | **RDP 無効化** | リモートデスクトップ経由の侵入を遮断 |
| 4 | **USB AutoRun 無効化** | USBメモリ経由の自動実行感染を防止 |
| 5 | **UAC 最大レベル** | 権限昇格による被害拡大を抑制 |

---

### 各モジュール 詳細解説

#### 1. CFA（コントロールドフォルダーアクセス）

**機能の特徴**  
Windows Defender に組み込まれたランサムウェア専用の防御機能。  
「保護されたフォルダー」（デスクトップ・ドキュメント・ピクチャ等）への書き込み・削除・名前変更を、  
**許可リストにないプロセスからはすべて拒否** する。

**なぜ強化が必要か**  
Windows のデフォルト状態では **CFA は無効**。  
ランサムウェアは正規プロセスに見せかけてファイルを暗号化するため、  
有効化しないと完全にすり抜けてしまう。IPA の「中小企業向けセキュリティ指針」でも有効化を推奨。

**手動操作の場所**  
`Windowsセキュリティ` → `ウイルスと脅威の防止` → `ランサムウェア防止`  
→「コントロールされたフォルダー アクセス」を **オン** にする

**レジストリ / PowerShell**  
CFA はレジストリ直接書き込みではなく Windows Defender の設定APIで管理。  
RansomShield では以下を呼び出す：
```powershell
Set-MpPreference -EnableControlledFolderAccess Enabled
```

---

#### 2. SMB / 管理共有ブロック

**機能の特徴**  
2つの対策をセットで適用する。  
① **管理共有の無効化**：Windowsが自動生成する `C$` `D$` `ADMIN$` などの隠し共有を削除し、再起動後も作らせない。  
② **ポート445 受信ブロック**：Windowsファイアウォールに受信拒否ルールを追加し、外部からの SMB 接続を物理的に遮断する。

**なぜ強化が必要か**  
WannaCry・NotPetya などの主要ランサムウェアは **SMB（ポート445）を悪用して社内LAN内を自動伝播** した。  
管理共有はデフォルトで有効になっており、正しい認証情報があればネットワーク越しにドライブ全体へアクセスできてしまう。  
「1台が感染したら全台が感染」を防ぐ最重要設定の一つ。

**手動操作の場所**  
- 管理共有の削除：`コンピュータの管理` → `システムツール` → `共有フォルダ` → `共有`  
  → `C$` / `ADMIN$` を右クリック → `共有の停止`（ただし再起動で復活するためレジストリ設定も必須）  
- ファイアウォール規則：`Windowsセキュリティ` → `ファイアウォールとネットワーク保護`  
  → `詳細設定` → `受信の規則` → `新しい規則` → ポート445をブロック

**レジストリ**  
```
HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters
  AutoShareWks = 0  (DWORD)   ← 再起動後に管理共有を自動作成しない
```

---

#### 3. RDP 無効化

**機能の特徴**  
リモートデスクトッププロトコル（ポート3389）を完全に無効化し、  
あわせてファイアウォールの「リモートデスクトップ」グループのルールも無効にする。

**なぜ強化が必要か**  
RDP はブルートフォース攻撃・パスワードスプレー・クレデンシャルスタッフィングの **最大の標的**。  
インターネットに公開されたRDPに対し、1日数千回の侵入試行が行われていることも珍しくない。  
自宅・中小企業PCはリモートを使わないケースが多いにもかかわらずデフォルトで有効になっていることがあり、  
放置するとバックドア同然の状態になる。

**手動操作の場所**  
`コントロールパネル` → `システムとセキュリティ` → `システム` → `リモートの設定`  
→「リモートデスクトップ」欄で **「このコンピューターへのリモート接続を許可しない」** を選択

**レジストリ**  
```
HKLM:\System\CurrentControlSet\Control\Terminal Server
  fDenyTSConnections = 1  (DWORD)   ← 1=無効化 / 0=有効
```

---

#### 4. USB AutoRun 無効化

**機能の特徴**  
すべてのドライブ種別（フロッピー・HDD・ネットワーク・CD/DVD・RAM・USB 等）の AutoRun を一括無効化する。  
値 `0xFF`（255）はビットフラグで「全ドライブタイプを対象」を意味する。

**なぜ強化が必要か**  
USB AutoRun 経由の感染は Stuxnet（2010年）以来、古典的かつ現在も使われ続ける手法。  
Windows 7 以降で AutoPlay のデフォルトが変更されたが、**AutoRun そのものはレジストリ設定で残っている**。  
「拾ったUSBを差し込む」「業者からもらったUSBを使う」といった行為が、  
このレジストリが設定されていないと即感染につながるリスクがある。

**手動操作の場所**  
`コントロールパネル` → `ハードウェアとサウンド` → `自動再生`  
→「すべてのメディアとデバイスで自動再生を使う」の **チェックを外す**  
※ 自動再生(AutoPlay)の無効化とは別に、**AutoRun はレジストリ設定が必要**。GUIだけでは不十分。

**レジストリ**  
```
HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer
  NoDriveTypeAutoRun = 0xFF  (DWORD)   ← 全ドライブのAutoRunを無効化
```

---

#### 5. UAC 最大レベル

**機能の特徴**  
UAC（ユーザーアカウント制御）の通知レベルを最大に設定する。  
`ConsentPromptBehaviorAdmin = 2` により、**あらゆる変更で確認ダイアログを表示**（セキュアデスクトップ使用）。  
`PromptOnSecureDesktop = 1` により、ダイアログ表示中は他のプロセスからのUI操作を遮断する。

**なぜ強化が必要か**  
Windowsのデフォルト設定は `ConsentPromptBehaviorAdmin = 5`（Windowsの変更のみ通知）。  
この設定ではサードパーティ製マルウェアが管理者権限を無断で取得できるケースがある。  
ランサムウェアは感染後に権限昇格を試みるため、**最大レベル(2)で昇格試行をすべて可視化・阻止** することが重要。

**手動操作の場所**  
`コントロールパネル` → `ユーザーアカウント` → `ユーザーアカウント制御設定の変更`  
→ スライダーを最上位 **「常に通知する」** に設定

**レジストリ**  
```
HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System
  ConsentPromptBehaviorAdmin = 2  (DWORD)   ← 2=常に通知 / 5=デフォルト
  PromptOnSecureDesktop      = 1  (DWORD)   ← 1=セキュアデスクトップで表示
```

---

### 対応する推奨対策

経済産業省・IPA「情報セキュリティ10大脅威 2024」の技術的対策項目を網羅しています。

> ランサムウェアによる被害 = **組織向け脅威 第1位**（2016年から9年連続）

---

### 攻撃チェーンと防衛の対応

ランサムウェアは「侵入→権限昇格→横展開→暗号化」という **5ステップの連鎖** で破壊する。  
RansomShield の5モジュールは、この連鎖を **各ステップで1:1に封じる** 設計になっている。

```
╔══════════════════════════════════════════════════════╗
║  ランサムウェア 攻撃チェーン  ×  RansomShield 防衛   ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  STEP 1  侵入口の探索                                ║
║          自動スキャナーが RDP(3389)・SMB(445) を検索 ║
║          ↓  ██ [3] RDP 無効化         → ポート封鎖  ║
║                                                      ║
║  STEP 2  侵入                                        ║
║          RDP ブルートフォース / USB AutoRun 実行      ║
║          ↓  ██ [4] USB AutoRun 無効化 → 自動実行封鎖 ║
║                                                      ║
║  STEP 3  権限昇格                                    ║
║          UAC を回避し管理者権限を奪取                ║
║          ↓  ██ [5] UAC 最大レベル     → 昇格を可視化 ║
║                                                      ║
║  STEP 4  横展開                                      ║
║          SMB 経由で社内 PC 全台へ自動伝播             ║
║          ↓  ██ [2] SMB/管理共有ブロック → LAN 遮断   ║
║                                                      ║
║  STEP 5  ファイル暗号化                              ║
║          ドキュメント・デスクトップを暗号化           ║
║          ↓  ██ [1] CFA               → 書き込み拒否  ║
║                                                      ║
║  ▓▓▓▓▓  身代金要求 ← ここに到達させない  ▓▓▓▓▓      ║
╚══════════════════════════════════════════════════════╝
```

> **どれか1つでも欠ければ、チェーンは繋がる。5つ揃って初めて「詰み」になる。**

---

### 「やらない」を選んだ場合のコスト

「自分には関係ない」——その判断が、どれほどの代償を生んできたか。

| 事例 | 被害の実態 |
|------|-----------|
| **WannaCry**（2017年・世界） | 150か国・20万台以上が感染。日立・Renault・FedEx・英国NHSが業務停止。SMBの脆弱性1つで全社に伝播 |
| **NotPetya**（2017年・世界） | 被害総額 **100億ドル超**。Maersk は全世界の物流が2週間停止。バックアップごと暗号化された |
| **半田病院**（2021年・国内） | 電子カルテが暗号化。復旧まで **約2か月**、費用 **約3億円**。手術・外来を全面停止 |
| **大阪急性期・総合医療センター**（2022年・国内） | 診療停止 **約2か月**。給食業者経由のVPN機器が侵入口。直接の担当者以外の穴から入られた |
| **中小企業平均**（IPA 調査） | 復旧費用 **300〜1,000万円**、業務停止期間 **平均3週間** |

> WannaCry は標的を選ばなかった。自動スキャナーが無防備なポートを見つけ、**数秒で侵入した**。  
> 「有名企業でもなく、お金もない自分は狙われない」——その前提は、すでに崩れている。

---

### よくある「やらない理由」と事実

**「アンチウイルスがあれば十分では？」**  
アンチウイルスは「既知の脅威の署名」で検知する。ランサムウェアはゼロデイ・難読化・正規プロセスへの寄生でこれを回避する。  
CFA は「何のプロセスか」ではなく「許可リストに載っているか」だけで判断するため、**未知の脅威・亜種・ゼロデイにも有効**。

**「自分は標的にされるほど重要ではない」**  
攻撃者は個人を標的にするのではなく、自動スキャナーで**条件を満たすPCを無差別に探す**。  
あなたのPCが「踏み台」になり、そこから取引先・顧客に被害が伝播した事例が国内でも複数ある。

**「設定を変えると業務に支障が出る」**  
RansomShield には **解除機能が同梱**されている。問題が出た場合は即座に元に戻せる。  
各設定は独立しており、「SMBのみ解除」「CFAのみ有効」といった部分適用も可能。  
「試してみる→問題なければ維持」のコストは、感染後の復旧コストと比べて桁が違う。

**「IT担当・上の人間に任せればいい」**  
IT担当が対処できるのは「報告を受けてから」。感染の進行は**報告の数時間前**に始まっている。  
エンドユーザー自身がPC1台を守ることが、組織全体への感染拡大を止める**最初の壁**になる。  
「誰かがやってくれる」という期待が、連鎖感染を許す最大の原因である。

---

### 使い方

#### 方法1: EXEをダブルクリック（推奨）
1. [Releases](../../releases) から `RansomShield.exe` をダウンロード
2. 右クリック → **「管理者として実行」**
3. メニューから操作

#### 方法2: PowerShellスクリプトで実行
```powershell
# 管理者PowerShellで実行
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\RansomShield.ps1
```

---

### スクリーンショット

```
========================================================
  RansomShield  ver 1.0.0
  ランサムウェア防衛ツール
========================================================

  [保護中  OK]  [1] CFA（コントロールドフォルダーアクセス）
  [保護中  OK]  [2] SMB/管理共有ブロック
  [保護中  OK]  [3] RDP 無効化
  [保護中  OK]  [4] USB AutoRun 無効化
  [保護中  OK]  [5] UAC 最大レベル

  防衛スコア: 5/5  [完全防衛]
```

---

### 動作環境

- Windows 10 / 11
- 管理者権限（自動昇格）

---

### ⚠️ 注意事項

- SMBブロックは **共有フォルダ機能** に影響します
- RDP無効化は **リモートデスクトップ接続** を使用している場合に影響します
- 企業・業務環境では必ずIT管理者と相談のうえご利用ください

詳細は [DISCLAIMER.md](DISCLAIMER.md) をご確認ください。

---

### ライセンス

[MIT License](LICENSE)

---

### 📖 このツールを作った経緯

ある日、取引先がランサムウェアに感染した。

すべてのファイルが暗号化され、業務は完全に止まった。復旧には多大な時間と人員が費やされた。その光景を目の当たりにして、「自分には関係ない」とは、もう思えなくなった。

私はIT企業の社員ではありません。20代から、IT系ではない会社の情報システム部員として働いてきた、いわば「社内のPC担当」です。華やかな技術者でも、セキュリティの専門家でもない。でも長年の現場経験を通じて、**「普通の人がどこで困るか」** を誰よりも肌で感じてきた人間です。

調べるほどに分かったことがあります。経済産業省やIPAが推奨するランサムウェア対策の多くは、**Windowsの標準機能だけで実現できる**。難しいコマンドも、高額なソフトも要らない。でも、それを知っている一般のユーザーはほとんどいない。

自分だけが知識を積んでも、自分のPCだけが守られても——それは自己満足でしかありません。人生の半ばを越えた今、積み上げてきたものを、必要としている誰かに届けたい。その一心でRansomShieldを作りました。

開発はGitHub Copilotと二人三脚で行いました。プログラマーではない私が、試行錯誤を繰り返しながら一つひとつ機能を積み上げ、Microsoftの誤検知申請まで乗り越えた記録が、このリポジトリの歴史そのものです。

コードはすべて公開しています。隠すものは何もありません。このツールが、あなたのPC一台を守る力になれれば、それだけで十分です。

> *「自分だけが助かっても意味がない。知識は、人のために使って初めて価値を持つ。」*

---

### 支援・寄付

このツールが役に立った場合、開発継続のためのご支援をいただけると幸いです。

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/fuchigami_michiaki)

📝 **[開発ストーリーを Qiita で読む](https://qiita.com/fuchigami-michiaki/items/f0f054830067ecde6037)**

---

---

## English

### Overview

RansomShield is a Windows security tool that lets you **apply, check, and revert**  
ransomware countermeasures recommended by Japan's METI and IPA — in one click.

It runs with administrator privileges and provides a CLI menu for managing each defense setting.

---

### Features (5 Modules)

| # | Feature | Description |
|---|---------|-------------|
| 1 | **CFA (Controlled Folder Access)** | Blocks ransomware from writing to protected folders |
| 2 | **SMB / Admin Share Block** | Prevents lateral movement over local networks |
| 3 | **RDP Disable** | Blocks intrusion via Remote Desktop Protocol |
| 4 | **USB AutoRun Disable** | Prevents auto-execution malware via USB drives |
| 5 | **UAC Maximum Level** | Limits privilege escalation damage |

---

### Alignment with Security Guidelines

Covers all technical countermeasure items from IPA's  
"Top 10 Information Security Threats 2024":

> Ransomware damage = **#1 organizational threat** (9 consecutive years since 2016)

---

### How to Use

#### Option 1: Run EXE (Recommended)
1. Download `RansomShield.exe` from [Releases](../../releases)
2. Right-click → **"Run as administrator"**
3. Use the CLI menu

#### Option 2: Run PowerShell Script
```powershell
# Run in Administrator PowerShell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\RansomShield.ps1
```

---

### Requirements

- Windows 10 / 11
- Administrator privileges (auto-elevation included)

---

### ⚠️ Disclaimer

- SMB block affects **shared folder** functionality
- RDP disable affects active **Remote Desktop** connections
- In corporate/business environments, consult your IT administrator before use

See [DISCLAIMER.md](DISCLAIMER.md) for full details.

---

### License

[MIT License](LICENSE)

---

### 📖 Why I Built This

One day, a business partner of mine was hit by ransomware.

Every file was encrypted. Operations came to a complete halt. Enormous time and resources were spent just to recover. Watching it unfold, I could no longer tell myself, *"that's someone else's problem."*

I am not a developer at a tech company. Since my twenties, I have worked as an in-house IT staff member at a non-IT company — the person people call when their PC doesn't work. Not a celebrated engineer, not a security expert. But through years of being on the front lines, I have seen firsthand **where ordinary people struggle**.

The more I researched, the clearer it became: most of the ransomware countermeasures recommended by Japan's Ministry of Economy, Trade and Industry (METI) and IPA can be implemented **using only Windows' built-in features**. No complex commands. No expensive software. Yet almost no ordinary user knows this.

Learning it all myself, protecting only my own PC — that would be nothing more than self-satisfaction. Now past the midpoint of my life, I want to pass on what I've built to the people who need it. That is the only reason RansomShield exists.

I developed this tool alongside GitHub Copilot. As a non-programmer, I worked through countless trial-and-error cycles, building each feature one by one — including navigating Microsoft's false positive submission process. The commit history of this repository is the honest record of that journey.

Every line of code is open. There is nothing to hide. If this tool can protect even one more PC, that is enough.

> *"Surviving alone is not enough. Knowledge only has value when it serves others."*

---

### Support / Donation

If this tool helped you, consider supporting continued development.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/fuchigami_michiaki)

📝 **[Read the development story on Qiita](https://qiita.com/fuchigami-michiaki/items/f0f054830067ecde6037)**