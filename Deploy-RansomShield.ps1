# ===========================================================
# Deploy-RansomShield.ps1
# RansomShield 展開ラッパースクリプト
# ===========================================================
# 【役割】
#   1. ネットワーク共有からRansomShield一式をローカルにコピー
#   2. INIファイルを読み込み、RansomShield.ps1 をサイレント適用
#
# 【使い方】
#   通常実行（デフォルトINI使用）:
#     .\Deploy-RansomShield.ps1
#
#   PC固有のINIを使う場合:
#     .\Deploy-RansomShield.ps1 -IniFile "\\fileserver\tools\RansomShield_PC01.ini"
#
#   ソース場所を指定する場合:
#     .\Deploy-RansomShield.ps1 -SourcePath "\\fileserver\tools\RansomShield"
# ===========================================================

param(
    # RansomShield一式が置かれているネットワーク共有（または絶対パス）
    [string]$SourcePath = '\\fileserver\tools\RansomShield',

    # 使用するINIファイルのパス（省略時はSourcePath内のデフォルトINIを使用）
    [string]$IniFile = '',

    # ローカルへのコピー先（省略時はProgramDataに展開）
    [string]$LocalPath = 'C:\ProgramData\RansomShield'
)

#region --- 管理者昇格 ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exe -like '*powershell*' -or $exe -like '*pwsh*') {
        Start-Process powershell -Verb RunAs -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -SourcePath `"$SourcePath`" -IniFile `"$IniFile`" -LocalPath `"$LocalPath`"")
    } else {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList "-SourcePath `"$SourcePath`" -IniFile `"$IniFile`" -LocalPath `"$LocalPath`""
    }
    exit
}
#endregion

function Write-Log([string]$msg, [string]$Color = 'White') {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts] $msg" -ForegroundColor $Color
}

# ===========================================================
# STEP 1: ローカルコピー先を準備
# ===========================================================
Write-Log "RansomShield 展開ラッパー 開始" Cyan
Write-Log "ローカルコピー先: $LocalPath" DarkGray

if (-not (Test-Path $LocalPath)) {
    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
    Write-Log "フォルダを作成しました: $LocalPath" DarkGray
}

# ===========================================================
# STEP 2: ネットワーク共有からローカルにコピー
#         ネットワーク不達の場合はローカルキャッシュを使用
# ===========================================================
$scriptFile = Join-Path $LocalPath 'RansomShield.ps1'

if (Test-Path $SourcePath) {
    Write-Log "ネットワーク共有からコピー中: $SourcePath" DarkGray
    try {
        Copy-Item (Join-Path $SourcePath 'RansomShield.ps1') $scriptFile -Force -ErrorAction Stop
        Write-Log "RansomShield.ps1 コピー完了" Green

        # INIファイルの決定
        if ([string]::IsNullOrEmpty($IniFile)) {
            # PC名に合致するINIがあればそちらを優先
            $pcIni  = Join-Path $SourcePath ("RansomShield_{0}.ini" -f $env:COMPUTERNAME)
            $defIni = Join-Path $SourcePath 'RansomShield_default.ini'
            $IniFile = if (Test-Path $pcIni) { $pcIni } else { $defIni }
        }

        if (Test-Path $IniFile) {
            Copy-Item $IniFile (Join-Path $LocalPath 'RansomShield.ini') -Force
            Write-Log ("INIコピー完了: {0}" -f (Split-Path $IniFile -Leaf)) Green
        } else {
            Write-Log "INIファイルが見つかりません: $IniFile" Yellow
            Write-Log "デフォルト設定（全有効）で続行します。" Yellow
        }
    } catch {
        Write-Log ("ネットワークコピー失敗: {0}" -f $_.Exception.Message) Yellow
        Write-Log "ローカルキャッシュで続行します。" Yellow
    }
} else {
    Write-Log "ネットワーク共有に接続できません: $SourcePath" Yellow
    if (Test-Path $scriptFile) {
        Write-Log "ローカルキャッシュを使用します。" Cyan
    } else {
        Write-Log "RansomShield.ps1 が見つかりません。終了します。" Red
        exit 1
    }
}

# ===========================================================
# STEP 3: INIを読み込んで設定を適用
# ===========================================================
$localIni = Join-Path $LocalPath 'RansomShield.ini'

if (-not (Test-Path $localIni)) {
    Write-Log "INIなし: 全設定有効・サイレントモードで適用します。" Yellow
}

Write-Log "RansomShield.ps1 を実行します..." Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $scriptFile `
    -Config $localIni

Write-Log "展開ラッパー 完了" Cyan
