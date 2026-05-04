#Requires -Version 5.1
<#
.SYNOPSIS
    编译鸿蒙 HAP 并备份带符号信息的 libentry.so

.DESCRIPTION
    调用 hvigorw 编译项目，编译完成后将 HAP 和带符号的 libentry.so
    按版本号归档到 backup/ 目录。

.PARAMETER BuildMode
    编译模式: debug 或 release，默认 debug（保留符号）

.PARAMETER BackupDir
    备份根目录，默认 ./backup

.PARAMETER HvigorwPath
    hvigorw 可执行文件路径，默认自动搜索

.EXAMPLE
    .\build_and_backup.ps1
    .\build_and_backup.ps1 -BuildMode release
    .\build_and_backup.ps1 -BuildMode debug -BackupDir D:\HapBackups
#>

param(
    [ValidateSet("debug", "release")]
    [string]$BuildMode = "debug",
    [string]$BackupDir = "./backup",
    [string]$HvigorwPath = ""
)

# ==================== 工具函数 ====================

function Write-Header {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# ==================== 解析版本号 ====================

$appJsonPath = Join-Path $PSScriptRoot ".." "AppScope" "app.json5"
if (-not (Test-Path $appJsonPath)) {
    Write-ErrorMsg "找不到 AppScope/app.json5: $appJsonPath"
    exit 1
}

$appJson = Get-Content $appJsonPath -Raw
# 简单提取 versionCode 和 versionName
$versionCode = [regex]::Match($appJson, '"versionCode"\s*:\s*(\d+)').Groups[1].Value
$versionName = [regex]::Match($appJson, '"versionName"\s*:\s*"([^"]+)"').Groups[1].Value
$bundleName = [regex]::Match($appJson, '"bundleName"\s*:\s*"([^"]+)"').Groups[1].Value

if (-not $versionCode -or -not $versionName) {
    Write-ErrorMsg "无法从 app.json5 解析版本号"
    exit 1
}

Write-Info "BundleName: $bundleName"
Write-Info "VersionCode: $versionCode"
Write-Info "VersionName: $versionName"

# ==================== 查找 hvigorw ====================

if ([string]::IsNullOrWhiteSpace($HvigorwPath)) {
    # 先检查 PATH
    $hvg = Get-Command hvigorw -ErrorAction SilentlyContinue
    if ($hvg) {
        $HvigorwPath = $hvg.Source
    } else {
        # 搜索常见路径
        $candidates = @(
            "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat",
            "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw",
            "$env:LOCALAPPDATA\OpenHarmony\Sdk\toolchains\*\hvigorw*"
        )
        foreach ($c in $candidates) {
            $found = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $HvigorwPath = $found.FullName
                break
            }
        }
    }
}

if (-not (Test-Path $HvigorwPath)) {
    Write-ErrorMsg "未找到 hvigorw。请通过 -HvigorwPath 指定路径，或将 DevEco Studio 的 tools\hvigor\bin 加入 PATH"
    exit 1
}

Write-Info "使用 hvigorw: $HvigorwPath"

# ==================== 编译 ====================

Write-Header "开始编译 [$BuildMode]"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $projectRoot

# 清理旧产物（可选，防止增量编译导致符号不一致）
Write-Info "清理旧构建产物..."
& $HvigorwPath clean --no-daemon 2>&1 | Out-Null

$taskName = "assemble$($BuildMode.Substring(0,1).ToUpper() + $BuildMode.Substring(1))"
Write-Info "执行编译任务: $taskName"
$buildOutput = & $HvigorwPath $taskName --no-daemon 2>&1
$buildExitCode = $LASTEXITCODE

if ($buildExitCode -ne 0) {
    Write-ErrorMsg "编译失败 (exit code: $buildExitCode)"
    $buildOutput | ForEach-Object { Write-Host $_ }
    exit 1
}

# 简单检查输出中是否有 BUILD SUCCESSFUL
if ($buildOutput -match "BUILD FAILED" -or $buildOutput -match "FAIL") {
    Write-ErrorMsg "编译输出检测到失败关键字"
    $buildOutput | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Info "编译成功"

# ==================== 定位产物 ====================

$hapDir = Join-Path $projectRoot "entry" "build" "default" "outputs" "default"
$symbolsDir = Join-Path $projectRoot "entry" "build" "default" "intermediates" "cmake" "default" "obj"

# HAP 文件
$hapFiles = Get-ChildItem $hapDir -Filter "*.hap" -ErrorAction SilentlyContinue
if (-not $hapFiles) {
    Write-ErrorMsg "未找到编译出的 HAP 文件"
    exit 1
}
$signedHap = $hapFiles | Where-Object { $_.Name -like "*-signed.hap" } | Select-Object -First 1
if (-not $signedHap) {
    $signedHap = $hapFiles | Select-Object -First 1
}

# 带符号的 libentry.so
$soFiles = Get-ChildItem $symbolsDir -Recurse -Filter "libentry.so" -ErrorAction SilentlyContinue
if (-not $soFiles) {
    Write-ErrorMsg "未找到带符号的 libentry.so"
    exit 1
}

Write-Info "HAP: $($signedHap.FullName)"
Write-Info "SO 文件数: $($soFiles.Count)"

# ==================== 备份 ====================

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupBase = Join-Path (Resolve-Path $BackupDir -ErrorAction SilentlyContinue) "v${versionName}_${versionCode}_${timestamp}"
$hapBackupDir = Join-Path $backupBase "hap"
$soBackupDir = Join-Path $backupBase "symbols"

New-Item -ItemType Directory -Force -Path $hapBackupDir | Out-Null
New-Item -ItemType Directory -Force -Path $soBackupDir | Out-Null

# 备份 HAP
Copy-Item $signedHap.FullName -Destination (Join-Path $hapBackupDir $signedHap.Name) -Force
Write-Info "已备份 HAP -> $hapBackupDir"

# 备份带符号的 SO（保留 ABI 目录结构）
foreach ($so in $soFiles) {
    # 提取 ABI 目录名，例如 arm64-v8a
    $abiDir = $so.Directory.Name
    $destDir = Join-Path $soBackupDir $abiDir
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item $so.FullName -Destination (Join-Path $destDir $so.Name) -Force
    Write-Info "已备份 SO [$abiDir] -> $destDir"
}

# 写入版本信息
$metaFile = Join-Path $backupBase "build_meta.txt"
@"
BundleName: $bundleName
VersionName: $versionName
VersionCode: $versionCode
BuildMode: $BuildMode
BuildTime: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
HAP: $($signedHap.Name)
SO_ABIs: $($soFiles | ForEach-Object { $_.Directory.Name } | Sort-Object -Unique | Join-String -Separator ', ')
"@ | Out-File -FilePath $metaFile -Encoding UTF8

Write-Header "备份完成"
Write-Info "备份目录: $backupBase"
Write-Info "  HAP -> $hapBackupDir"
Write-Info "  Symbols -> $soBackupDir"
