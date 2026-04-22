#Requires -Version 5.1
<#
.SYNOPSIS
    鸿蒙应用崩溃循环测试脚本（改进版）

.DESCRIPTION
    通过 hdc 循环拉起指定鸿蒙应用，等待其崩溃后收集故障日志存档到 PC。
    检测策略（优先级从高到低）：
      1. 故障日志文件出现：启动前记录基准文件列表，监控 faultlogger 目录是否有新文件
      2. 进程消失：pidof 检测应用进程从有到无
      3. hilog 关键字：检测 SIGSEGV/SIGABRT/faultlogger/GWP-ASan 等关键字

    Ctrl+C 中断：脚本已做处理，按一次 Ctrl+C 即可安全退出。

.PARAMETER BundleName
    应用包名，默认 dev.hackeris.hish.test

.PARAMETER AbilityName
    入口 Ability 名称，默认 EntryAbility

.PARAMETER LogDir
    PC 端日志保存目录，默认 ./crash_logs

.PARAMETER PollInterval
    进程状态轮询间隔（秒），默认 3

.PARAMETER PostCrashDelay
    崩溃后等待日志写入的时间（秒），默认 5

.PARAMETER MaxIterations
    最大循环次数，0 表示无限循环，默认 0

.PARAMETER CleanDeviceLogs
    每轮开始前是否清理设备上的旧故障日志，默认 true

.PARAMETER LaunchMode
    启动模式: start (aa start) 或 test (aa test)，默认 start

.EXAMPLE
    .\crash_loop_test.ps1
    .\crash_loop_test.ps1 -MaxIterations 10 -PollInterval 2
    .\crash_loop_test.ps1 -LaunchMode test -AbilityName TestAbility
#>

param(
    [string]$BundleName = "dev.hackeris.hish.test",
    [string]$AbilityName = "EntryAbility",
    [string]$LogDir = "./crash_logs",
    [int]$PollInterval = 3,
    [int]$PostCrashDelay = 5,
    [int]$MaxIterations = 0,
    [bool]$CleanDeviceLogs = $true,
    [ValidateSet("start", "test")]
    [string]$LaunchMode = "start"
)

# ==================== 初始化 ====================

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

# 全局中断标志
$script:Interrupted = $false

# 注册 Ctrl+C 中断处理
try {
    [Console]::CancelKeyPress.AddHandler({
        param($sender, $e)
        $e.Cancel = $true
        $script:Interrupted = $true
        Write-Warn "`n收到中断信号 (Ctrl+C)，正在安全退出..."
    })
} catch {
    # 如果无法注册事件处理，忽略
}

# 检查 hdc 命令
$hdcPath = Get-Command hdc -ErrorAction SilentlyContinue
if (-not $hdcPath) {
    $commonPaths = @(
        "$env:LOCALAPPDATA\OpenHarmony\Sdk\*\toolchains\*\hdc.exe",
        "$env:LOCALAPPDATA\Huawei\Sdk\*\toolchains\*\hdc.exe",
        "$env:HOMEDRIVE$env:HOMEPATH\AppData\Local\OpenHarmony\Sdk\*\toolchains\*\hdc.exe"
    )
    foreach ($p in $commonPaths) {
        $found = Get-Item $p -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $hdcPath = $found.FullName
            break
        }
    }
}

if (-not $hdcPath) {
    Write-ErrorMsg "未找到 hdc 命令。请确保鸿蒙 SDK 已安装，并将 hdc 所在目录添加到系统 PATH 环境变量。"
    Write-ErrorMsg "常见路径示例: %LOCALAPPDATA%\OpenHarmony\Sdk\<version>\toolchains\<version>"
    exit 1
}

Write-Info "使用 hdc: $hdcPath"

# 检查设备连接
Write-Info "检查设备连接..."
$deviceList = & $hdcPath list targets 2>&1
if ($deviceList -match "Empty" -or $deviceList -match "error" -or [string]::IsNullOrWhiteSpace($deviceList)) {
    Write-ErrorMsg "没有检测到已连接的设备，请通过 hdc 连接设备后再试。"
    exit 1
}
Write-Info "已连接设备:`n$deviceList"

# 确保日志目录存在
$LogDir = Resolve-Path -Path $LogDir -ErrorAction SilentlyContinue
if (-not $LogDir) {
    New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot ".." "crash_logs") | Out-Null
    $LogDir = Resolve-Path -Path (Join-Path $PSScriptRoot ".." "crash_logs")
}
Write-Info "PC 端日志保存目录: $LogDir"

# ==================== 核心函数 ====================

function Invoke-HdcShell {
    param([string]$Command)
    # 如果已收到中断信号，跳过 hdc 调用
    if ($script:Interrupted) { return "" }
    $output = & $hdcPath shell $Command 2>&1
    return ($output -join "`n").Trim()
}

function Invoke-HdcFileRecv {
    param(
        [string]$RemotePath,
        [string]$LocalDir
    )
    if ($script:Interrupted) { return "" }
    $output = & $hdcPath file recv "$RemotePath" "$LocalDir" 2>&1
    return ($output -join "`n").Trim()
}

function Start-App {
    if ($LaunchMode -eq "test") {
        $cmd = "aa test -b $BundleName -m entry_test"
        Write-Info "通过测试框架启动: $cmd"
    } else {
        $cmd = "aa start -a $AbilityName -b $BundleName"
        Write-Info "直接启动应用: $cmd"
    }
    $result = Invoke-HdcShell -Command $cmd
    Write-Info "启动结果: $result"
    return $result
}

function Stop-App {
    Write-Info "强制停止应用: $BundleName"
    $result = Invoke-HdcShell -Command "aa force-stop $BundleName"
    Start-Sleep -Seconds 1
    return $result
}

function Clear-DeviceFaultLogs {
    Write-Info "清理设备旧故障日志..."
    Invoke-HdcShell -Command "rm -f /data/log/faultlog/faultlogger/*" | Out-Null
}

function Get-AppPid {
    $result = Invoke-HdcShell -Command "pidof $BundleName"
    if ([string]::IsNullOrWhiteSpace($result) -or $result -match "fail" -or $result -match "error" -or $result -match "Cannot") {
        return $null
    }
    $pid = ($result -split "\s+" | Select-Object -First 1).Trim()
    if ($pid -match "^\d+$") {
        return $pid
    }
    return $null
}

function Get-FaultLoggerFiles {
    $result = Invoke-HdcShell -Command "ls -1 /data/log/faultlog/faultlogger/ 2>/dev/null"
    if ([string]::IsNullOrWhiteSpace($result) -or $result -match "No such file") {
        return @()
    }
    return $result -split "`r?`n" | Where-Object { $_.Trim() -ne "" -and $_ -notmatch "^total\s+\d+" } | ForEach-Object { $_.Trim() }
}

function Wait-ForCrash {
    param(
        [string[]]$BaselineLogs,
        [int]$TimeoutSeconds = 0
    )

    $startTime = Get-Date
    $lastPid = $null
    $crashKeywords = @("SIGSEGV", "SIGABRT", "SIGILL", "SIGBUS", "SIGFPE", "SIGTRAP",
                       "faultlogger", "GWP-ASan", "AddressSanitizer", "MemoryTagging",
                       "HeapBufferOverflow", "UseAfterFree", "DoubleFree",
                       "Abort message", "runtime error")

    Write-Info "开始监控崩溃（检测方式：故障日志/进程消失/hilog关键字）..."

    while ($true) {
        # 检查中断标志
        if ($script:Interrupted) {
            Write-Warn "监控被用户中断"
            return @{ Crashed = $false; Method = "interrupted" }
        }

        Start-Sleep -Seconds $PollInterval

        # 检测 1：新的故障日志文件出现（最可靠）
        $currentLogs = Get-FaultLoggerFiles
        $newLogs = $currentLogs | Where-Object { $BaselineLogs -notcontains $_ }
        if ($newLogs -and $newLogs.Count -gt 0) {
            Write-Info "检测到新故障日志: $($newLogs -join ', ')"
            return @{ Crashed = $true; Method = "faultlogger" }
        }

        # 检测 2：进程消失
        $currentPid = Get-AppPid
        if ($lastPid -and -not $currentPid) {
            Write-Info "检测到应用进程已退出 (原 PID: $lastPid)"
            return @{ Crashed = $true; Method = "pid_gone" }
        }
        if ($currentPid) {
            $lastPid = $currentPid
        }

        # 检测 3：hilog 关键字
        $hilogContent = Invoke-HdcShell -Command "hilog -d | tail -n 200"
        foreach ($kw in $crashKeywords) {
            if ($hilogContent -match $kw) {
                Write-Info "检测到 hilog 崩溃关键字: $kw"
                return @{ Crashed = $true; Method = "hilog_keyword" }
            }
        }

        # 状态打印
        if ($currentPid) {
            Write-Host "  应用运行中 (PID: $currentPid) ..." -ForegroundColor DarkGray
        } else {
            Write-Host "  等待应用启动..." -ForegroundColor DarkGray
        }

        # 超时检查
        if ($TimeoutSeconds -gt 0) {
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-Warn "等待超时 (${TimeoutSeconds}s)"
                return @{ Crashed = $false; Method = "timeout" }
            }
        }
    }
}

function Collect-FaultLogs {
    param(
        [string]$TargetDir,
        [int]$RunIndex
    )

    $collectedCount = 0

    # 只采集 faultlogger 下与目标应用相关的故障日志
    $faultLoggerDir = "/data/log/faultlog/faultlogger/"
    Write-Info "扫描故障日志目录: $faultLoggerDir"
    $files = Invoke-HdcShell -Command "ls -1 $faultLoggerDir 2>/dev/null"

    if (-not [string]::IsNullOrWhiteSpace($files) -and -not ($files -match "No such file")) {
        $fileList = $files -split "`r?`n" | Where-Object { $_.Trim() -ne "" -and $_ -notmatch "^total\s+\d+" }
        foreach ($file in $fileList) {
            $file = $file.Trim()
            if ([string]::IsNullOrWhiteSpace($file)) { continue }
            # 只采集属于目标应用的故障日志
            if ($file -notmatch [regex]::Escape($BundleName)) { continue }

            $remotePath = "$faultLoggerDir$file"
            Write-Info "  拉取故障日志: $file"
            $recvResult = Invoke-HdcFileRecv -RemotePath $remotePath -LocalDir $TargetDir
            Write-Host "    $recvResult" -ForegroundColor DarkGray
            $collectedCount++
        }
    } else {
        Write-Warn "faultlogger 目录为空或不存在"
    }

    if ($collectedCount -eq 0) {
        Write-Warn "未找到 $BundleName 的故障日志文件"
    }

    # 同时导出 hilog 和 dump 作为上下文参考
    $hilogFile = Join-Path $TargetDir "hilog_${RunIndex}.txt"
    Write-Info "  导出完整 hilog 到: $hilogFile"
    $hilogContent = Invoke-HdcShell -Command "hilog -d | tail -n 1000"
    if (-not [string]::IsNullOrWhiteSpace($hilogContent)) {
        $hilogContent | Out-File -FilePath $hilogFile -Encoding UTF8
    }

    $dumpFile = Join-Path $TargetDir "app_dump_${RunIndex}.txt"
    $dumpContent = Invoke-HdcShell -Command "aa dump -a"
    if ($dumpContent) {
        $dumpContent | Out-File -FilePath $dumpFile -Encoding UTF8
    }

    return $collectedCount
}

# ==================== 主循环 ====================

Write-Header "鸿蒙崩溃循环测试开始"
Write-Info "目标应用: $BundleName/$AbilityName"
Write-Info "启动模式: $LaunchMode"
if ($MaxIterations -eq 0) {
    Write-Info "循环次数: 无限 (按 Ctrl+C 停止)"
} else {
    Write-Info "循环次数: $MaxIterations"
}

$iteration = 0
$totalLogsCollected = 0

try {
    while (-not $script:Interrupted) {
        if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) {
            Write-Header "已达到最大迭代次数 $MaxIterations"
            break
        }
        $iteration++

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $runLogDir = Join-Path $LogDir "run_${timestamp}_#$($iteration.ToString('000'))"
        New-Item -ItemType Directory -Force -Path $runLogDir | Out-Null

        Write-Header "第 $iteration 轮测试"
        Write-Info "开始时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Info "本轮日志目录: $runLogDir"

        # 清理旧日志
        if ($CleanDeviceLogs) {
            Clear-DeviceFaultLogs
        }

        # 确保应用不在运行
        Stop-App | Out-Null
        Start-Sleep -Seconds 1

        # 记录启动前的日志基准
        $baselineLogs = Get-FaultLoggerFiles
        Write-Info "启动前故障日志基准: $($baselineLogs.Count) 个文件"

        # 启动应用
        Start-App | Out-Null
        Start-Sleep -Seconds 3  # 给应用充分启动时间

        # 等待崩溃
        $result = Wait-ForCrash -BaselineLogs $baselineLogs
        $crashed = $result.Crashed
        $detectMethod = $result.Method

        if ($detectMethod -eq "interrupted") {
            Write-Warn "本轮被用户中断"
            break
        }

        if (-not $crashed) {
            Write-Warn "本轮未检测到崩溃，强制停止应用后继续下一轮"
            Stop-App | Out-Null
        } else {
            Write-Info "崩溃检测方式: $detectMethod"
            # 等待日志写入磁盘
            Write-Info "等待 ${PostCrashDelay}s 让日志完成写入..."
            Start-Sleep -Seconds $PostCrashDelay
        }

        # 收集日志
        Write-Info "收集故障日志..."
        $count = Collect-FaultLogs -TargetDir $runLogDir -RunIndex $iteration
        $totalLogsCollected += $count
        Write-Info "本轮收集到 $count 个日志文件"

        Write-Info "第 $iteration 轮完成"

        # 短暂停，避免过于频繁
        Start-Sleep -Seconds 2
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C 在 PowerShell 中产生的异常，已通过 CancelKeyPress 处理
    Write-Warn "测试被用户中断 (PipelineStoppedException)"
} catch {
    Write-ErrorMsg "发生异常: $_"
} finally {
    # 注销事件处理
    try {
        [Console]::CancelKeyPress.RemoveHandler({})
    } catch {}

    Write-Header "测试结束"
    Write-Info "总轮数: $iteration"
    Write-Info "总日志文件数: $totalLogsCollected"
    Write-Info "日志根目录: $LogDir"
    Write-Info "如需停止应用，请运行: hdc shell aa force-stop $BundleName"
}
