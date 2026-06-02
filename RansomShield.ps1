# ===========================================================
# RansomShield.ps1  v1.1.1
# ===========================================================
# (C) 2026  All rights reserved.
# ※ このスクリプトはPS2EXEでEXE化して配布してください
# ===========================================================

#region --- 管理者昇格 ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exe -like '*powershell*' -or $exe -like '*pwsh*') {
        Start-Process powershell -Verb RunAs -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"")
    } else {
        Start-Process -FilePath $exe -Verb RunAs
    }
    exit
}
#endregion

#region --- 定数 ---
$VERSION = '1.1.1'
$PRODUCT = 'RansomShield'
$LINE    = '=' * 56
$SEP     = '-' * 56
#endregion

#region --- ヘルパー関数 ---
function Write-Header {
    Clear-Host
    Write-Host $LINE -ForegroundColor Cyan
    Write-Host ("  {0}  ver {1}" -f $PRODUCT, $VERSION) -ForegroundColor Cyan
    Write-Host "  ランサムウェア防衛ツール" -ForegroundColor Cyan
    Write-Host $LINE -ForegroundColor Cyan
    Write-Host ""
}

function Write-Sep { Write-Host $SEP -ForegroundColor DarkGray }

function Get-YesNo([string]$label) {
    return if ($label -eq 'yes') { Write-Host "[有効]"   -ForegroundColor Green  -NoNewline }
           else                  { Write-Host "[無効]"   -ForegroundColor Red    -NoNewline }
}

function Pause-Any([string]$msg = "  何かキーを押すと戻ります...") {
    Write-Host ""
    Write-Host $msg -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Write-SmbStatus {
    # SMB状態を3段階でカラー表示（左カラム形式）
    $reg = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    $av  = (Get-ItemProperty $reg -Name AutoShareWks -EA SilentlyContinue).AutoShareWks
    $fw  = Get-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' -EA SilentlyContinue
    $c   = Get-SmbShare -Name 'C$' -EA SilentlyContinue
    Write-Host '  ' -NoNewline
    if (($av -eq 0) -and ($null -ne $fw)) {
        if ($c) { Write-Host '[再起動待ち]  ' -NoNewline -ForegroundColor Yellow }
        else    { Write-Host '[保護中  OK]  ' -NoNewline -ForegroundColor Green  }
    } else {
        Write-Host '[未設定  !!]  ' -NoNewline -ForegroundColor Red
    }
    Write-Host '[2] SMB/管理共有ブロック'
}

function Write-StatusRow([bool]$ok, [string]$num, [string]$label) {
    $st    = if ($ok) { '[保護中  OK]' } else { '[未設定  !!]' }
    $color = if ($ok) { 'Green' }        else { 'Red' }
    Write-Host '  ' -NoNewline
    Write-Host $st -NoNewline -ForegroundColor $color
    Write-Host "  $num $label"
}
#endregion

#region --- 状態検出 ---
function Get-SmbStatus {
    $reg  = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    $av   = (Get-ItemProperty $reg -Name AutoShareWks -EA SilentlyContinue).AutoShareWks
    $fw   = Get-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' -EA SilentlyContinue
    # C$ はWindows が削除後も即時再作成するため条件から除外
    # AutoShareWks=0 により次回起動以降は作成されなくなる
    return ($av -eq 0) -and ($null -ne $fw)
}

function Get-CfaStatus {
    $v = (Get-MpPreference -EA SilentlyContinue).EnableControlledFolderAccess
    return ($v -eq 1)
}

function Get-RdpStatus {
    $v = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -EA SilentlyContinue).fDenyTSConnections
    return ($v -eq 1)
}

function Get-AutoRunStatus {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name NoDriveTypeAutoRun -EA SilentlyContinue).NoDriveTypeAutoRun
    return ($v -eq 0xFF)
}

function Get-UacStatus {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name ConsentPromptBehaviorAdmin -EA SilentlyContinue).ConsentPromptBehaviorAdmin
    return ($v -eq 2)
}

function Get-AllStatus {
    return [ordered]@{
        smb     = Get-SmbStatus
        cfa     = Get-CfaStatus
        rdp     = Get-RdpStatus
        autorun = Get-AutoRunStatus
        uac     = Get-UacStatus
    }
}

function Format-Status([bool]$v) {
    if ($v) { return "[保護中  OK]" } else { return "[未設定  !!]" }
}
#endregion

#region --- 適用/解除 関数 ---

# -- SMB/管理共有 --
function Enable-SmbHardening {
    $reg = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    Set-ItemProperty $reg -Name AutoShareWks -Value 0 -Type DWord
    foreach ($n in @('C$','D$','E$','F$','ADMIN$')) {
        if (Get-SmbShare -Name $n -EA SilentlyContinue) {
            Remove-SmbShare -Name $n -Force
            Write-Host ("    {0} 共有削除" -f $n)
        }
    }
    Update-SmbBlockRule   # 信頼IPを考慮してルールを構築
    Write-Host "    SMB/管理共有ブロック 完了" -ForegroundColor Green
}

function Disable-SmbHardening {
    $reg = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    Remove-ItemProperty $reg -Name AutoShareWks -EA SilentlyContinue
    Remove-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' -EA SilentlyContinue
    Write-Host "    SMB/管理共有 解除完了（C$は次回起動時に復元）" -ForegroundColor Magenta
}

# --- SMB 信頼IP管理 ---

$SMB_TRUST_REG = 'HKLM:\SOFTWARE\RansomShield'

function Get-SmbTrustedIPs {
    try {
        $raw = (Get-ItemProperty $SMB_TRUST_REG -Name SmbTrustedIPs -EA Stop).SmbTrustedIPs
        return @($raw | ConvertFrom-Json)
    } catch { return @() }
}

function Save-SmbTrustedIPs([string[]]$IPs) {
    if (-not (Test-Path $SMB_TRUST_REG)) { New-Item $SMB_TRUST_REG -Force | Out-Null }
    Set-ItemProperty $SMB_TRUST_REG -Name SmbTrustedIPs -Value ($IPs | ConvertTo-Json -Compress) -Type String
}

function Get-IPv4RangesExcluding([string[]]$ExcludeIPs) {
    # 指定IPを除いた全IPv4範囲を返す（BLOCKルールのRemoteAddressに使用）
    $sorted = $ExcludeIPs | ForEach-Object {
        $p = $_ -split '\.'
        [int64]$p[0]*16777216 + [int64]$p[1]*65536 + [int64]$p[2]*256 + [int64]$p[3]
    } | Sort-Object -Unique

    $ranges = [System.Collections.Generic.List[string]]::new()
    $start  = [int64]0

    function IntToIP([int64]$n) {
        '{0}.{1}.{2}.{3}' -f [int]($n -shr 24), [int](($n -shr 16) -band 0xFF), [int](($n -shr 8) -band 0xFF), [int]($n -band 0xFF)
    }

    foreach ($ip in $sorted) {
        if ($ip -gt $start) {
            $ranges.Add( "$(IntToIP $start)-$(IntToIP ($ip - 1))" )
        }
        $start = $ip + 1
    }
    if ($start -le 4294967295) {
        $ranges.Add( "$(IntToIP $start)-255.255.255.255" )
    }
    return $ranges.ToArray()
}

function Update-SmbBlockRule {
    # BLOCKルールを信頼IPを除外した形で再構築
    Remove-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' -EA SilentlyContinue

    $trusted = Get-SmbTrustedIPs
    if ($trusted.Count -eq 0) {
        # 信頼IP未設定: 全ブロック
        New-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' `
            -Direction Inbound -Protocol TCP -LocalPort 445 `
            -RemoteAddress Any -Action Block -Profile Any | Out-Null
    } else {
        # 信頼IP設定あり: 信頼IP以外をブロック
        $blockRanges = Get-IPv4RangesExcluding -ExcludeIPs $trusted
        if ($blockRanges.Count -gt 0) {
            New-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' `
                -Direction Inbound -Protocol TCP -LocalPort 445 `
                -RemoteAddress $blockRanges -Action Block -Profile Any | Out-Null
        }
        Write-Host ("    信頼IP {0}件を除外してSMBブロックを再設定しました" -f $trusted.Count) -ForegroundColor Cyan
    }
}

function Show-SmbExceptionMenu {
    while ($true) {
        Write-Header
        Write-Host "  ■ SMB 信頼デバイス管理 (複合機・プリンターなど)" -ForegroundColor Yellow
        Write-Sep
        Write-Host "  ここに登録したIPアドレスのみ、SMBブロック中でも" -ForegroundColor DarkGray
        Write-Host "  ファイル転送（スキャン保存など）が可能になります。" -ForegroundColor DarkGray
        Write-Host ""

        $trusted = Get-SmbTrustedIPs
        if ($trusted.Count -eq 0) {
            Write-Host "  登録済み信頼IP: なし (全ブロック中)" -ForegroundColor Yellow
        } else {
            Write-Host "  登録済み信頼IP:" -ForegroundColor White
            for ($i = 0; $i -lt $trusted.Count; $i++) {
                Write-Host ("    [{0}] {1}" -f ($i + 1), $trusted[$i]) -ForegroundColor Cyan
            }
        }

        Write-Host ""
        Write-Sep
        Write-Host "  [A] IPアドレスを追加 (複合機・プリンターなど)"
        Write-Host "  [D] IPアドレスを削除"
        Write-Host "  [B] 戻る"
        Write-Host ""
        $c = Read-Host "  選択"

        switch ($c.ToUpper()) {
            'A' {
                $ip = (Read-Host "  追加するIPアドレスを入力 (例: 192.168.1.100)").Trim()
                if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    $list = @(Get-SmbTrustedIPs) + $ip | Select-Object -Unique
                    Save-SmbTrustedIPs -IPs $list
                    # SMBブロックが有効なら即座にルール更新
                    if (Get-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' -EA SilentlyContinue) {
                        Update-SmbBlockRule
                    }
                    Write-Host ("  {0} を信頼IPに追加しました。" -f $ip) -ForegroundColor Green
                } else {
                    Write-Host "  無効なIPアドレスです。" -ForegroundColor Red
                }
                Pause-Any
            }
            'D' {
                $trusted = Get-SmbTrustedIPs
                if ($trusted.Count -eq 0) {
                    Write-Host "  削除するIPがありません。" -ForegroundColor Yellow
                    Pause-Any
                } else {
                    $idx = Read-Host "  削除する番号を入力"
                    $i = [int]$idx - 1
                    if ($i -ge 0 -and $i -lt $trusted.Count) {
                        $removed = $trusted[$i]
                        $newList = @($trusted | Where-Object { $_ -ne $removed })
                        Save-SmbTrustedIPs -IPs $newList
                        if (Get-NetFirewallRule -DisplayName 'Block-SMB-Inbound-445' -EA SilentlyContinue) {
                            Update-SmbBlockRule
                        }
                        Write-Host ("  {0} を削除しました。" -f $removed) -ForegroundColor Magenta
                    } else {
                        Write-Host "  無効な番号です。" -ForegroundColor Red
                    }
                    Pause-Any
                }
            }
            'B' { return }
        }
    }
}


# -- コントロールドフォルダーアクセス --
function Enable-Cfa {
    Set-MpPreference -EnableControlledFolderAccess Enabled
    Write-Host "    コントロールドフォルダーアクセス 有効化完了" -ForegroundColor Green
}

function Disable-Cfa {
    Set-MpPreference -EnableControlledFolderAccess Disabled
    Write-Host "    コントロールドフォルダーアクセス 無効化完了" -ForegroundColor Magenta
}

function Show-CfaAllowMenu {
    # よく使うアプリの候補リスト
    $candidates = [ordered]@{
        'Python 3.12 (システム)' = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python312\python.exe"
        'Python 3.11 (システム)' = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python311\python.exe"
        'Python 3.10 (システム)' = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python310\python.exe"
        'venv Python (このフォルダ)' = (Join-Path (Split-Path $MyInvocation.ScriptName) '.venv\Scripts\python.exe')
        'yt-dlp.exe' = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python312\Scripts\yt-dlp.exe"
        'ffmpeg.exe' = 'C:\ffmpeg\bin\ffmpeg.exe'
    }

    while ($true) {
        Write-Header
        Write-Host "  ■ CFA 許可アプリ管理" -ForegroundColor Yellow
        Write-Host "  ここに登録したアプリは、保護フォルダへの書き込みが許可されます。" -ForegroundColor DarkGray
        Write-Sep

        $current = @((Get-MpPreference).ControlledFolderAccessAllowedApplications)
        if ($current.Count -eq 0 -or ($current.Count -eq 1 -and $current[0] -eq '')) {
            Write-Host "  登録済み許可アプリ: なし" -ForegroundColor Yellow
        } else {
            Write-Host "  登録済み許可アプリ:" -ForegroundColor White
            for ($i = 0; $i -lt $current.Count; $i++) {
                $exists = Test-Path $current[$i]
                $mark   = if ($exists) { '  ' } else { '?' }
                Write-Host ("    [{0}] {1} {2}" -f ($i + 1), $mark, $current[$i]) -ForegroundColor Cyan
            }
        }

        Write-Host ""
        Write-Sep
        Write-Host "  [A] パスを直接入力して追加"
        Write-Host "  [Q] よく使うアプリから選んで追加"
        Write-Host "  [D] 削除"
        Write-Host "  [B] 戻る"
        Write-Host ""
        $c = Read-Host "  選択"

        switch ($c.ToUpper()) {
            'A' {
                $path = (Read-Host "  追加するアプリの完全パスを入力").Trim()
                if ($path -and (Test-Path $path)) {
                    Add-MpPreference -ControlledFolderAccessAllowedApplications $path
                    Write-Host ("  {0} を許可リストに追加しました。" -f $path) -ForegroundColor Green
                } elseif ($path) {
                    $yn = Read-Host "  ファイルが見つかりません。それでも追加しますか？ (Y/N)"
                    if ($yn.ToUpper() -eq 'Y') {
                        Add-MpPreference -ControlledFolderAccessAllowedApplications $path
                        Write-Host ("  {0} を追加しました。" -f $path) -ForegroundColor Yellow
                    }
                }
                Pause-Any
            }
            'Q' {
                Write-Host ""
                Write-Host "  よく使うアプリ:" -ForegroundColor White
                $keys = @($candidates.Keys)
                for ($i = 0; $i -lt $keys.Count; $i++) {
                    $p = $candidates[$keys[$i]]
                    $mark = if (Test-Path $p) { '[存在]' } else { '[なし]' }
                    Write-Host ("    [{0}] {1} {2}" -f ($i + 1), $mark, $keys[$i]) -ForegroundColor Cyan
                    Write-Host ("         {0}" -f $p) -ForegroundColor DarkGray
                }
                Write-Host "    [B] キャンセル"
                Write-Host ""
                $sel = Read-Host "  番号を選択"
                if ($sel.ToUpper() -ne 'B') {
                    $idx = [int]$sel - 1
                    if ($idx -ge 0 -and $idx -lt $keys.Count) {
                        $path = $candidates[$keys[$idx]]
                        if (Test-Path $path) {
                            Add-MpPreference -ControlledFolderAccessAllowedApplications $path
                            Write-Host ("  {0} を追加しました。" -f $path) -ForegroundColor Green
                        } else {
                            Write-Host "  ファイルが見つかりません: $path" -ForegroundColor Red
                        }
                    }
                }
                Pause-Any
            }
            'D' {
                $current = @((Get-MpPreference).ControlledFolderAccessAllowedApplications)
                if ($current.Count -eq 0 -or ($current.Count -eq 1 -and $current[0] -eq '')) {
                    Write-Host "  削除するアプリがありません。" -ForegroundColor Yellow
                } else {
                    $idx = [int](Read-Host "  削除する番号を入力") - 1
                    if ($idx -ge 0 -and $idx -lt $current.Count) {
                        Remove-MpPreference -ControlledFolderAccessAllowedApplications $current[$idx]
                        Write-Host ("  {0} を削除しました。" -f $current[$idx]) -ForegroundColor Magenta
                    } else {
                        Write-Host "  無効な番号です。" -ForegroundColor Red
                    }
                }
                Pause-Any
            }
            'B' { return }
        }
    }
}

# -- RDP --
function Disable-Rdp {
    $path = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    Set-ItemProperty $path -Name fDenyTSConnections -Value 1 -Type DWord
    Disable-NetFirewallRule -DisplayGroup 'Remote Desktop' -EA SilentlyContinue
    Write-Host "    RDP 無効化完了" -ForegroundColor Green
}

function Enable-Rdp {
    $path = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    Set-ItemProperty $path -Name fDenyTSConnections -Value 0 -Type DWord
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -EA SilentlyContinue
    Write-Host "    RDP 有効化完了" -ForegroundColor Magenta
}

# -- USB AutoRun --
function Disable-AutoRun {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }
    Set-ItemProperty $path -Name NoDriveTypeAutoRun -Value 0xFF -Type DWord
    Write-Host "    USB AutoRun 無効化完了" -ForegroundColor Green
}

function Enable-AutoRun {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    Remove-ItemProperty $path -Name NoDriveTypeAutoRun -EA SilentlyContinue
    Write-Host "    USB AutoRun 解除完了" -ForegroundColor Magenta
}

# -- UAC --
function Set-UacMax {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty $path -Name ConsentPromptBehaviorAdmin -Value 2 -Type DWord
    Set-ItemProperty $path -Name PromptOnSecureDesktop      -Value 1 -Type DWord
    Write-Host "    UAC 最大レベル設定完了" -ForegroundColor Green
}

function Reset-Uac {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty $path -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord
    Set-ItemProperty $path -Name PromptOnSecureDesktop      -Value 1 -Type DWord
    Write-Host "    UAC 標準レベルに戻しました" -ForegroundColor Magenta
}
#endregion

#region --- メニュー画面 ---

# 診断画面
function Show-Diagnosis {
    Write-Header
    $s = Get-AllStatus
    $score = ($s.Values | Where-Object { $_ }).Count
    Write-Host "  ■ 現在のセキュリティ診断結果" -ForegroundColor Yellow
    Write-Sep
    Write-Host "  状態            No  内容" -ForegroundColor DarkGray
    Write-Sep
    $cfaSt    = if ($s.cfa) { '[保護中  OK]' } else { '[未設定  !!]' }
    $cfaColor = if ($s.cfa) { 'Green' }        else { 'Red' }
    Write-Host '  ' -NoNewline
    Write-Host $cfaSt -NoNewline -ForegroundColor $cfaColor
    Write-Host '  [1] CFA 暗号化ブロック  ' -NoNewline
    Write-Host '<<核心防御>>' -ForegroundColor Magenta
    Write-SmbStatus
    Write-StatusRow $s.rdp     '[3]' 'RDP 無効化'
    Write-StatusRow $s.autorun '[4]' 'USB AutoRun 無効化'
    Write-StatusRow $s.uac     '[5]' 'UAC 最大レベル'
    Write-Sep
    $color = if ($score -ge 4) { 'Green' } elseif ($score -ge 2) { 'Yellow' } else { 'Red' }
    Write-Host ("  防衛スコア: {0}/5  " -f $score) -NoNewline
    $label = switch ($score) {
        5 { "[完全防衛]" } 4 { "[ほぼ安全]" } 3 { "[要改善  ]" } default { "[危険    ]" }
    }
    Write-Host $label -ForegroundColor $color
    Write-Host ""
    Pause-Any
}

# 一括適用
function Invoke-ApplyAll {
    Write-Header
    Write-Host "  ■ 全防衛設定を適用します" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  【注意事項】" -ForegroundColor Red
    Write-Host "  ・コントロールドフォルダー有効時、一部アプリが保護フォルダへ"
    Write-Host "    書き込めなくなる場合があります（Windows Defender設定から許可可能）"
    Write-Host "  ・RDP無効化後はリモートデスクトップ接続ができなくなります"
    Write-Host "  ・SMB設定は次回PC起動後に完全反映されます"
    Write-Host "  ・本ツール使用による損害について作者は責任を負いません"
    Write-Host ""
    $c = Read-Host "  続行しますか？ (Y/N)"
    if ($c.ToUpper() -ne 'Y') { return }
    Write-Host ""
    Enable-SmbHardening
    Enable-Cfa
    Disable-Rdp
    Disable-AutoRun
    Set-UacMax
    Write-Host ""
    Write-Host "  >> 全防衛設定の適用が完了しました。" -ForegroundColor Green
    Pause-Any
}

# 一括解除
function Invoke-UndoAll {
    Write-Header
    Write-Host "  ■ 全防衛設定を解除します" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  【警告】解除するとPCがランサムウェアの攻撃を受けやすくなります。" -ForegroundColor Red
    Write-Host "  本当に解除してよい場合のみ続行してください。"
    Write-Host ""
    $c = Read-Host "  解除を続行しますか？ (Y/N)"
    if ($c.ToUpper() -ne 'Y') { return }
    Write-Host ""
    Disable-SmbHardening
    Disable-Cfa
    Enable-Rdp
    Enable-AutoRun
    Reset-Uac
    Write-Host ""
    Write-Host "  設定解除が完了しました。" -ForegroundColor Magenta
    Pause-Any
}

# 個別設定メニュー
function Show-IndividualMenu {
    while ($true) {
        Write-Header
        $s = Get-AllStatus
        Write-Host "  ■ 個別設定" -ForegroundColor Yellow
        Write-Sep
        Write-Host "  状態            No  内容" -ForegroundColor DarkGray
        Write-Sep
        $cfaSt2    = if ($s.cfa) { '[保護中  OK]' } else { '[未設定  !!]' }
        $cfaColor2 = if ($s.cfa) { 'Green' }        else { 'Red' }
        Write-Host '  ' -NoNewline
        Write-Host $cfaSt2 -NoNewline -ForegroundColor $cfaColor2
        Write-Host '  [1] CFA 暗号化ブロック  ' -NoNewline
        Write-Host '<<核心防御>>' -ForegroundColor Magenta
        Write-SmbStatus
        Write-StatusRow $s.rdp     '[3]' 'RDP 無効化'
        Write-StatusRow $s.autorun '[4]' 'USB AutoRun 無効化'
        Write-StatusRow $s.uac     '[5]' 'UAC 最大レベル'
        Write-Sep
        Write-Host "  [B] 戻る"
        Write-Host ""
        $c = Read-Host "  番号を選択"
        switch ($c.ToUpper()) {
            '1' {
                if ($s.cfa) {
                    # CFA ON 時: サブメニューで「解除」or「許可アプリ管理」を選択
                    Write-Header
                    Write-Host "  ■ CFA（コントロールドフォルダーアクセス）設定" -ForegroundColor Yellow
                    Write-Sep
                    $allowedCount = @((Get-MpPreference).ControlledFolderAccessAllowedApplications | Where-Object { $_ }).Count
                    Write-Host ("  許可済みアプリ: {0}件" -f $allowedCount) -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "  [1] CFAを無効化"
                    Write-Host "  [2] 許可アプリ管理 - 書き込みを許可するアプリを追加・削除"
                    Write-Host "  [B] 戻る"
                    Write-Host ""
                    $sub = Read-Host "  選択"
                    switch ($sub.ToUpper()) {
                        '1' { Disable-Cfa; Pause-Any }
                        '2' { Show-CfaAllowMenu }
                    }
                } else {
                    Write-Host "  【注意】一部アプリが保護フォルダーに書き込めなくなる場合があります。" -ForegroundColor Yellow
                    Enable-Cfa
                    Pause-Any
                }
            }
            '2' {
                if ($s.smb) {
                    # SMB ON 時: サブメニューで「解除」or「信頼デバイス管理」を選択
                    Write-Header
                    Write-Host "  ■ SMB/管理共有ブロック 設定" -ForegroundColor Yellow
                    Write-Sep
                    $trusted = Get-SmbTrustedIPs
                    if ($trusted.Count -gt 0) {
                        Write-Host ("  信頼デバイス: {0}件 登録中" -f $trusted.Count) -ForegroundColor Cyan
                        $trusted | ForEach-Object { Write-Host ("    - {0}" -f $_) -ForegroundColor Cyan }
                    } else {
                        Write-Host "  信頼デバイス: なし (全IPブロック中)" -ForegroundColor Yellow
                    }
                    Write-Host ""
                    Write-Host "  [1] SMBブロックを解除"
                    Write-Host "  [2] 信頼デバイス管理 - 複合機・プリンターなどのIPを登録"
                    Write-Host "  [B] 戻る"
                    Write-Host ""
                    $sub = Read-Host "  選択"
                    switch ($sub.ToUpper()) {
                        '1' { Disable-SmbHardening; Pause-Any }
                        '2' { Show-SmbExceptionMenu }
                    }
                } else {
                    Enable-SmbHardening
                    Pause-Any
                }
            }
            '3' {
                if ($s.rdp) { Enable-Rdp } else {
                    Write-Host "  【注意】無効化後はリモートデスクトップ接続ができなくなります。" -ForegroundColor Yellow
                    Disable-Rdp
                }
                Pause-Any
            }
            '4' {
                if ($s.autorun) { Enable-AutoRun } else { Disable-AutoRun }
                Pause-Any
            }
            '5' {
                if ($s.uac) { Reset-Uac } else { Set-UacMax }
                Pause-Any
            }
            'B' { return }
        }
    }
}

# SMBブロック履歴
function Show-SmbBlockLog {
    Write-Header
    Write-Host "  ■ SMB / ポート445 ブロック履歴" -ForegroundColor Yellow
    Write-Sep

    $found = $false

    # --- 優先1: Windowsファイアウォールログファイル ---
    $fwLog = "$env:SystemRoot\System32\LogFiles\Firewall\pfirewall.log"
    if (Test-Path $fwLog) {
        Write-Host "  ファイアウォールログを解析中..." -ForegroundColor DarkGray
        $drops = Get-Content $fwLog -ErrorAction SilentlyContinue | Where-Object {
            $_ -notmatch '^#'
        } | ForEach-Object {
            $p = $_ -split '\s+'
            if ($p.Count -ge 8 -and $p[2] -eq 'DROP' -and $p[7] -eq '445') { $_ }
        }
        if ($drops -and @($drops).Count -gt 0) {
            $found = $true
            $total = @($drops).Count
            Write-Host ""
            Write-Host ("  ポート445 DROPブロック件数: {0} 件" -f $total) -ForegroundColor Red
            Write-Sep
            Write-Host "  ▼ 最近のブロック記録 (最新15件):" -ForegroundColor White
            Write-Host ""
            Write-Host ("  {0,-18} {1,-18} {2,-8} {3}" -f "日時", "送信元IP", "Src.Port", "プロトコル") -ForegroundColor DarkGray
            Write-Host ("  " + ('-' * 60)) -ForegroundColor DarkGray
            @($drops) | Select-Object -Last 15 | ForEach-Object {
                $p = $_ -split '\s+'
                Write-Host ("  {0,-18} {1,-18} {2,-8} {3}" -f "$($p[0]) $($p[1])", $p[4], $p[5], $p[3])
            }
            Write-Sep
            Write-Host ""
            Write-Host "  ▼ 送信元IP 上位5件:" -ForegroundColor Yellow
            Write-Host ""
            @($drops) | ForEach-Object { ($_ -split '\s+')[4] } |
                Group-Object | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
                $bar   = [string]::new([char]0x2588, [Math]::Min($_.Count, 35))
                $color = if ($_.Count -ge 5) { 'Red' } else { 'Yellow' }
                Write-Host ("    {0,4}回  " -f $_.Count) -NoNewline
                Write-Host $bar -NoNewline -ForegroundColor $color
                Write-Host ("  {0}" -f $_.Name)
            }
        }
    }

    # --- 優先2: セキュリティログ EventID 5157 ---
    if (-not $found) {
        Write-Host "  セキュリティログ (EventID:5157) を確認中..." -ForegroundColor DarkGray
        try {
            $evts = Get-WinEvent -FilterHashtable @{
                LogName   = 'Security'; Id = 5157
                StartTime = (Get-Date).AddDays(-30)
            } -MaxEvents 2000 -ErrorAction Stop | Where-Object {
                try {
                    $x = [xml]$_.ToXml()
                    ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'DestPort' }).'#text' -eq '445'
                } catch { $false }
            }
            if (@($evts).Count -gt 0) {
                $found = $true
                Write-Host ""
                Write-Host ("  SMB(445) ブロック件数 (過去30日): {0} 件" -f @($evts).Count) -ForegroundColor Red
                Write-Sep
                $evts | Select-Object -First 10 | ForEach-Object {
                    $x = [xml]$_.ToXml()
                    $src = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'SourceAddress' }).'#text'
                    Write-Host ("  {0}  送信元: {1}" -f $_.TimeCreated.ToString('MM/dd HH:mm:ss'), $src)
                }
            }
        } catch { }
    }

    # --- データなし ---
    if (-not $found) {
        Write-Host ""
        Write-Host "  SMBブロックの記録が見つかりません。" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  ログを有効にするには (どちらか一方):" -ForegroundColor Cyan
        Write-Host "  [方法A] ファイアウォールログ有効化:" -ForegroundColor White
        Write-Host "    Windows セキュリティ → ファイアウォール → 詳細設定" -ForegroundColor DarkGray
        Write-Host "    → プロパティ → ログ → ドロップされたパケット: はい" -ForegroundColor DarkGray
        Write-Host "  [方法B] 監査ポリシー有効化 (管理者PowerShell):" -ForegroundColor White
        Write-Host "    auditpol /set /subcategory:`"フィルタリングプラットフォームの接続`" /failure:enable" -ForegroundColor DarkGray
    }

    Write-Host ""
    Pause-Any
}

# RDP接続試行履歴
function Show-RdpBlockLog {
    Write-Header
    Write-Host "  ■ RDP 接続試行履歴 (ポート3389)" -ForegroundColor Yellow
    Write-Sep

    $found = $false

    # --- 優先1: TerminalServices-RemoteConnectionManager ---
    try {
        $evts = Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' `
                             -ErrorAction Stop |
                Where-Object { $_.Id -eq 261 } |
                Select-Object -First 200
        if (@($evts).Count -gt 0) {
            $found = $true
            $total    = @($evts).Count
            $today    = (Get-Date).Date
            $todayCnt = @($evts | Where-Object { $_.TimeCreated -ge $today }).Count
            $weekCnt  = @($evts | Where-Object { $_.TimeCreated -ge $today.AddDays(-7) }).Count

            Write-Host ""
            Write-Host ("  RDP接続試行件数 (直近200件まで): {0} 件" -f $total) -ForegroundColor Red
            Write-Host ("  本日:{0,4}件  /  過去7日:{1,4}件" -f $todayCnt, $weekCnt) -ForegroundColor Yellow
            Write-Sep
            Write-Host "  ▼ 最近の接続試行 (最新15件):" -ForegroundColor White
            Write-Host ""
            Write-Host ("  {0,-17} {1}" -f "日時", "内容") -ForegroundColor DarkGray
            Write-Host ("  " + ('-' * 65)) -ForegroundColor DarkGray
            $evts | Select-Object -First 15 | ForEach-Object {
                $msg = ($_.Message -split "`n")[0] -replace '^\s+',''
                if ($msg.Length -gt 55) { $msg = $msg.Substring(0, 52) + '...' }
                Write-Host ("  {0,-17} {1}" -f $_.TimeCreated.ToString('MM/dd HH:mm:ss'), $msg)
            }
        }
    } catch { }

    # --- 優先2: セキュリティログ EventID 4625 LogonType=10 (RDP認証失敗) ---
    if (-not $found) {
        try {
            $evts = Get-WinEvent -FilterHashtable @{
                LogName   = 'Security'; Id = 4625
                StartTime = (Get-Date).AddDays(-30)
            } -MaxEvents 500 -ErrorAction Stop | Where-Object {
                try {
                    $x = [xml]$_.ToXml()
                    ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'LogonType' }).'#text' -eq '10'
                } catch { $false }
            }
            if (@($evts).Count -gt 0) {
                $found = $true
                Write-Host ""
                Write-Host ("  RDP認証失敗 (過去30日): {0} 件" -f @($evts).Count) -ForegroundColor Red
                Write-Sep
                $evts | Select-Object -First 10 | ForEach-Object {
                    $x    = [xml]$_.ToXml()
                    $user = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
                    $ip   = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'IpAddress' }).'#text'
                    Write-Host ("  {0}  ユーザー: {1,-20} 送信元: {2}" -f $_.TimeCreated.ToString('MM/dd HH:mm:ss'), $user, $ip)
                }
            }
        } catch { }
    }

    # --- データなし ---
    if (-not $found) {
        Write-Host ""
        Write-Host "  RDP接続試行の記録が見つかりません。" -ForegroundColor Green
        Write-Host "  RDPが正常にブロックされているか、接続試行がない状態です。" -ForegroundColor DarkGray
    }

    Write-Host ""
    Pause-Any
}

# AutoRun - USB接続履歴（ブロック記録代替）
function Show-AutoRunLog {
    Write-Header
    Write-Host "  ■ USB/外部メディア 接続履歴" -ForegroundColor Yellow
    Write-Sep
    Write-Host "  AutoRun抑止はレジストリ設定のため、ブロックイベントは記録されません。" -ForegroundColor DarkGray
    Write-Host "  代わりに USB デバイスの接続履歴を表示します。" -ForegroundColor DarkGray
    Write-Host ""

    try {
        $evts = Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' `
                             -ErrorAction Stop |
                Where-Object { $_.Id -eq 2003 } |
                Select-Object -First 50
        if (@($evts).Count -gt 0) {
            Write-Host ("  USB/外部デバイス接続件数 (直近50件): {0} 件" -f @($evts).Count) -ForegroundColor Yellow
            Write-Sep
            Write-Host "  ▼ 最近の接続記録 (最新15件):" -ForegroundColor White
            Write-Host ""
            $evts | Select-Object -First 15 | ForEach-Object {
                $msg = ($_.Message -split "`n")[0] -replace '^\s+',''
                if ($msg.Length -gt 60) { $msg = $msg.Substring(0,57) + '...' }
                Write-Host ("  {0,-17} {1}" -f $_.TimeCreated.ToString('MM/dd HH:mm:ss'), $msg)
            }
        } else {
            Write-Host "  USB接続の記録はありません。" -ForegroundColor Green
        }
    } catch {
        # System logからUSBストレージを確認
        try {
            $evts = Get-WinEvent -FilterHashtable @{
                LogName = 'System'; Id = 20001
            } -MaxEvents 20 -ErrorAction Stop
            $evts | Select-Object -First 10 | ForEach-Object {
                Write-Host ("  {0,-17} {1}" -f $_.TimeCreated.ToString('MM/dd HH:mm:ss'), $_.Message.Substring(0, [Math]::Min(60, $_.Message.Length)))
            }
        } catch {
            Write-Host "  USB接続履歴ログが取得できませんでした。" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  AutoRunが有効の場合: USB挿入時に自動実行プログラムが起動します。" -ForegroundColor Cyan
    Write-Host "  現在の設定 (NoDriveTypeAutoRun=255) により自動実行は抑止中です。" -ForegroundColor Cyan
    Write-Host ""
    Pause-Any
}

# UAC - 管理者昇格ログ
function Show-UacLog {
    Write-Header
    Write-Host "  ■ UAC 管理者操作ログ" -ForegroundColor Yellow
    Write-Sep
    Write-Host "  UACの「拒否」クリックはWindowsに記録されません。" -ForegroundColor DarkGray
    Write-Host "  代わりに管理者権限での実行が承認されたプロセスを表示します。" -ForegroundColor DarkGray
    Write-Host ""

    try {
        $evts = Get-WinEvent -FilterHashtable @{
            LogName   = 'Security'; Id = 4688
            StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 200 -ErrorAction Stop | Where-Object {
            try {
                $x = [xml]$_.ToXml()
                ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'TokenElevationType' }).'#text' -eq '%%1937'
                # %%1937 = TokenElevationTypeFull (完全な管理者トークン)
            } catch { $false }
        }
        if (@($evts).Count -gt 0) {
            Write-Host ("  管理者昇格で起動したプロセス (過去7日): {0} 件" -f @($evts).Count) -ForegroundColor Yellow
            Write-Sep
            Write-Host "  ▼ 最近の昇格実行 (最新15件):" -ForegroundColor White
            Write-Host ""
            Write-Host ("  {0,-17} {1}" -f "日時", "実行プログラム") -ForegroundColor DarkGray
            Write-Host ("  " + ('-' * 65)) -ForegroundColor DarkGray
            $evts | Select-Object -First 15 | ForEach-Object {
                $x    = [xml]$_.ToXml()
                $proc = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'NewProcessName' }).'#text'
                $proc = [System.IO.Path]::GetFileName($proc)
                Write-Host ("  {0,-17} {1}" -f $_.TimeCreated.ToString('MM/dd HH:mm:ss'), $proc)
            }
        } else {
            Write-Host "  管理者昇格の記録がありません。" -ForegroundColor Green
            Write-Host "  または プロセス生成の監査が無効です。" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  監査を有効にするには (管理者PowerShell):" -ForegroundColor Cyan
            Write-Host "    auditpol /set /subcategory:`"プロセス作成`" /success:enable" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  セキュリティログの取得に失敗しました。" -ForegroundColor Red
        Write-Host ("  詳細: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
    }

    Write-Host ""
    Pause-Any
}

# ブロック履歴 統合メニュー
function Show-BlockLogMenu {
    while ($true) {
        Write-Header
        Write-Host "  ■ セキュリティブロック履歴" -ForegroundColor Yellow
        Write-Sep

        # 各機能の直近件数をサマリー表示
        $cfaCnt  = try { @(Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -EA Stop | Where-Object { $_.Id -eq 1123 } | Select-Object -First 1).Count } catch { '?' }
        $todayStr = (Get-Date).Date.ToString('yyyy-MM-dd')
        Write-Host ("  {0,-6} {1,-10} {2}" -f "番号", "件数(累計)", "機能") -ForegroundColor DarkGray
        Write-Sep

        # CFA
        $cfaTotal = try { @(Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -EA Stop | Where-Object { $_.Id -eq 1123 }).Count } catch { '-' }
        $cfaColor = if ($cfaTotal -is [int] -and $cfaTotal -gt 0) { 'Red' } else { 'Green' }
        Write-Host "  [1]  " -NoNewline
        Write-Host ("{0,-10}" -f "$cfaTotal 件") -NoNewline -ForegroundColor $cfaColor
        Write-Host "  CFA  暗号化ブロック (ファイル書き込み遮断)"

        # SMB
        $fwLog  = "$env:SystemRoot\System32\LogFiles\Firewall\pfirewall.log"
        $smbCnt = if (Test-Path $fwLog) {
            try { @(Get-Content $fwLog -EA Stop | Where-Object { $_ -notmatch '^#' } | Where-Object { ($_ -split '\s+')[2] -eq 'DROP' -and ($_ -split '\s+')[7] -eq '445' }).Count } catch { '?' }
        } else { '(ログ未設定)' }
        $smbColor = if ($smbCnt -is [int] -and $smbCnt -gt 0) { 'Red' } elseif ($smbCnt -is [int]) { 'Green' } else { 'Yellow' }
        Write-Host "  [2]  " -NoNewline
        Write-Host ("{0,-10}" -f "$smbCnt 件") -NoNewline -ForegroundColor $smbColor
        Write-Host "  SMB  ポート445ブロック (共有フォルダー攻撃)"

        # RDP
        $rdpCnt = try { @(Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' -EA Stop | Where-Object { $_.Id -eq 261 } | Select-Object -First 200).Count } catch { '-' }
        $rdpColor = if ($rdpCnt -is [int] -and $rdpCnt -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "  [3]  " -NoNewline
        Write-Host ("{0,-10}" -f "$rdpCnt 件") -NoNewline -ForegroundColor $rdpColor
        Write-Host "  RDP  接続試行 (遠隔侵入試み)"

        # AutoRun
        Write-Host "  [4]  " -NoNewline
        Write-Host ("{0,-10}" -f "(接続履歴)") -NoNewline -ForegroundColor DarkGray
        Write-Host "  USB  外部メディア接続履歴"

        # UAC
        Write-Host "  [5]  " -NoNewline
        Write-Host ("{0,-10}" -f "(昇格ログ)") -NoNewline -ForegroundColor DarkGray
        Write-Host "  UAC  管理者昇格 実行ログ"

        Write-Sep
        Write-Host "  [B] 戻る"
        Write-Host ""
        $c = Read-Host "  番号を選択"
        switch ($c.ToUpper()) {
            '1' { Show-CfaBlockLog }
            '2' { Show-SmbBlockLog }
            '3' { Show-RdpBlockLog }
            '4' { Show-AutoRunLog  }
            '5' { Show-UacLog      }
            'B' { return }
        }
    }
}


function Show-CfaBlockLog {
    param([int]$MaxRecords = 500)
    Write-Header
    Write-Host "  ■ CFA ブロック履歴レポート" -ForegroundColor Yellow
    Write-Sep
    Write-Host "  Windowsイベントログ (EventID:1123) を取得中..." -ForegroundColor DarkGray

    try {
        $events = Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' `
                               -ErrorAction Stop |
                  Where-Object { $_.Id -eq 1123 } |
                  Select-Object -First $MaxRecords
    } catch {
        Write-Host ""
        Write-Host "  イベントログの取得に失敗しました。" -ForegroundColor Red
        Write-Host ("  詳細: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        Pause-Any
        return
    }

    Write-Host ""
    if (-not $events -or @($events).Count -eq 0) {
        Write-Host "  ブロック記録はありません。" -ForegroundColor Green
        Write-Host "  CFAが無効、またはブロックが一度も発生していない状態です。" -ForegroundColor DarkGray
        Pause-Any
        return
    }

    $total    = @($events).Count
    $today    = (Get-Date).Date
    $todayCnt = @($events | Where-Object { $_.TimeCreated -ge $today }).Count
    $weekCnt  = @($events | Where-Object { $_.TimeCreated -ge $today.AddDays(-7) }).Count
    $monCnt   = @($events | Where-Object { $_.TimeCreated -ge $today.AddDays(-30) }).Count

    Write-Host ("  取得件数 (最大{0}件): " -f $MaxRecords) -NoNewline
    Write-Host ("{0} 件" -f $total) -ForegroundColor Red
    Write-Host ""
    Write-Host ("  本日:{0,4}件  /  過去7日:{1,4}件  /  過去30日:{2,4}件" -f $todayCnt, $weekCnt, $monCnt) -ForegroundColor Yellow
    Write-Sep

    # イベントをパース
    $parsed = $events | ForEach-Object {
        $appName  = '不明'
        $filePath = '不明'
        try {
            $xml  = [xml]$_.ToXml()
            $data = $xml.Event.EventData.Data
            foreach ($d in $data) {
                if ($d.Name -match 'Process|Application') {
                    $appName = [System.IO.Path]::GetFileName(($d.'#text' -replace '"','').Trim())
                }
                if ($d.Name -match 'Path|File|Target') {
                    $filePath = ($d.'#text' -replace '"','').Trim()
                }
            }
        } catch {
            $m = $_.Message
            $a = [regex]::Match($m, '(?:Application Name|Process Name|アプリケーション):\s*(.+)')
            $f = [regex]::Match($m, '(?:Target|Path|ファイル|パス):\s*(.+)')
            if ($a.Success) { $appName  = [System.IO.Path]::GetFileName($a.Groups[1].Value.Trim()) }
            if ($f.Success) { $filePath = $f.Groups[1].Value.Trim() }
        }
        [PSCustomObject]@{ Time = $_.TimeCreated; AppName = $appName; Path = $filePath }
    }

    # 最近15件の詳細
    Write-Host "  ▼ 最近のブロック記録 (最新15件):" -ForegroundColor White
    Write-Host ""
    Write-Host ("  {0,-17} {1,-26} {2}" -f "日時", "ブロックされたアプリ", "対象パス") -ForegroundColor DarkGray
    Write-Host ("  " + ('-' * 76)) -ForegroundColor DarkGray
    $parsed | Select-Object -First 15 | ForEach-Object {
        $app  = $_.AppName
        if ($app.Length  -gt 24) { $app  = $app.Substring(0,21)  + '...' }
        $path = $_.Path
        if ($path.Length -gt 32) { $path = '...' + $path.Substring($path.Length - 29) }
        Write-Host ("  {0,-17} {1,-26} {2}" -f $_.Time.ToString('MM/dd HH:mm:ss'), $app, $path)
    }

    Write-Sep

    # ブロック頻度ランキング
    Write-Host ""
    Write-Host "  ▼ ブロック頻度 上位5アプリ:" -ForegroundColor Yellow
    Write-Host ""
    $parsed | Group-Object AppName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
        $barLen = [Math]::Min($_.Count, 35)
        $bar    = [string]::new([char]0x2588, $barLen)   # ████
        $color  = if ($_.Count -ge 10) { 'Red' } elseif ($_.Count -ge 3) { 'Yellow' } else { 'White' }
        Write-Host ("    {0,4}回  " -f $_.Count) -NoNewline
        Write-Host $bar -NoNewline -ForegroundColor $color
        Write-Host ("  {0}" -f $_.Name)
    }

    Write-Host ""
    Write-Sep
    Write-Host "  ヒント: 業務ツール・DLアプリがブロックされている場合は..." -ForegroundColor Cyan
    Write-Host "  メインメニュー [4] 個別設定 → [1] CFA → 許可アプリに追加すると解除できます。" -ForegroundColor Cyan
    Write-Host ""
    Pause-Any
}

# メインメニュー
function Show-MainMenu {
    while ($true) {
        Write-Header
        $s = Get-AllStatus
        $score = ($s.Values | Where-Object { $_ }).Count
        $scoreColor = if ($score -ge 4) { 'Green' } elseif ($score -ge 2) { 'Yellow' } else { 'Red' }
        Write-Host ("  防衛スコア: {0}/5" -f $score) -ForegroundColor $scoreColor
        Write-Host ""
        Write-Host "  [1] 診断             - セキュリティ状態を確認" -ForegroundColor White
        Write-Host "  [2] 全防衛設定を適用   - ランサムウェア対策を一括有効化" -ForegroundColor Green
        Write-Host "  [3] 全設定を解除       - 設定を元に戻す" -ForegroundColor Magenta
        Write-Host "  [4] 個別設定           - 機能を個別にON/OFF" -ForegroundColor White
        Write-Host "  [5] ブロック履歴ログ   - CFA/SMB/RDP/USB/UAC のブロック記録を確認" -ForegroundColor Cyan
        Write-Sep
        Write-Host "  [Q] 終了" -ForegroundColor DarkGray
        Write-Host ""
        $c = Read-Host "  選択 (1/2/3/4/5/Q)"
        switch ($c.ToUpper()) {
            '1' { Show-Diagnosis }
            '2' { Invoke-ApplyAll }
            '3' { Invoke-UndoAll }
            '4' { Show-IndividualMenu }
            '5' { Show-BlockLogMenu }
            'Q' {
                Write-Host ""
                Write-Host "  終了します。" -ForegroundColor DarkGray
                exit
            }
        }
    }
}
#endregion

# --- エントリポイント ---
Show-MainMenu
