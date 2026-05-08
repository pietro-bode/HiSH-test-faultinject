#Requires -Version 5.1
<#
.SYNOPSIS
    鸿蒙应用崩溃循环测试脚本（GWP-ASan 恢复模式增强版）

.DESCRIPTION
    通过 hdc 循环拉起指定鸿蒙应用，等待其崩溃后收集故障日志存档到 PC。
    支持 GWP-ASan 恢复模式下的三种情况处理：
      1. 应用退出，只产生 crash 日志 -> 只收集 crash 日志
      2. 应用退出，产生了 crash + gwpasan 日志 -> 同时收集到同一目录
      3. 应用产生了 gwpasan 日志但没有 crash 退出 -> 5分钟超时后 kill，重新测试

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

.PARAMETER GwpasanDir
    GWP-ASan 日志目录，默认自动探测

.PARAMETER TimeoutSeconds
    单轮测试超时时间（秒），默认 300（5分钟）

.EXAMPLE
    .\crash_loop_test.ps1
    .\crash_loop_test.ps1 -MaxIterations 10 -PollInterval 2
    .\crash_loop_test.ps1 -GwpasanDir "/data/log/gwpasan"
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
    [string]$LaunchMode = "start",
    [string]$GwpasanDir = "",
    [int]$TimeoutSeconds = 300
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

# ==================== 探测 GWP-ASan 日志路径 ====================

$GwpasanCandidateDirs = @(
    "/data/log/gwpasan/",
    "/data/log/faultlog/gwpasan/",
    "/dev/asanlog/"
)

$script:ActualGwpasanDir = $null

if (-not [string]::IsNullOrWhiteSpace($GwpasanDir)) {
    $script:ActualGwpasanDir = $GwpasanDir
    Write-Info "使用指定的 GWP-ASan 日志路径: $($script:ActualGwpasanDir)"
} else {
    foreach ($d in $GwpasanCandidateDirs) {
        $result = Invoke-HdcShell -Command "ls -d $d 2>/dev/null"
        if (-not [string]::IsNullOrWhiteSpace($result) -and -not ($result -match "No such file")) {
            $script:ActualGwpasanDir = $d
            Write-Info "探测到 GWP-ASan 日志路径: $($script:ActualGwpasanDir)"
            break
        }
    }
    if (-not $script:ActualGwpasanDir) {
        Write-Warn "未探测到 GWP-ASan 日志目录，将使用默认路径 /data/log/gwpasan/"
        $script:ActualGwpasanDir = "/data/log/gwpasan/"
    }
}

# ==================== 核心函数 ====================

function Invoke-HdcShell {
    param([string]$Command)
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

function Enable-GwpAsanProp {
    # 开启 GWP-ASan
    $prop = "gwp_asan.enable.app.$BundleName"
    Write-Info "设置 GWP-ASan 系统属性: $prop=true"
    $result1 = Invoke-HdcShell -Command "param set $prop true"
    Write-Info "设置结果: $result1"
    # 设置可恢复模式（崩溃后不杀死进程，便于采集日志）
    $recoverable = "gwp_asan.recoverable.app.$BundleName"
    Write-Info "设置 GWP-ASan 恢复属性: $recoverable=true"
    $result2 = Invoke-HdcShell -Command "param set $recoverable true"
    Write-Info "设置结果: $result2"
    return "$result1; $result2"
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

function Clear-DeviceLogs {
    Write-Info "清理设备旧故障日志..."
    Invoke-HdcShell -Command "rm -f /data/log/faultlog/faultlogger/*" | Out-Null
    if ($script:ActualGwpasanDir) {
        Invoke-HdcShell -Command "rm -f $($script:ActualGwpasanDir)*" | Out-Null
    }
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
    return $result -split "`r?`n" |
        Where-Object { $_.Trim() -ne "" -and $_ -notmatch "^total\s+\d+" -and -not $_.Trim().StartsWith("stacktrace") } |
        ForEach-Object { $_.Trim() }
}

function Get-GwpasanFiles {
    if (-not $script:ActualGwpasanDir) { return @() }
    $result = Invoke-HdcShell -Command "ls -1 $($script:ActualGwpasanDir) 2>/dev/null"
    if ([string]::IsNullOrWhiteSpace($result) -or $result -match "No such file") {
        return @()
    }
    return $result -split "`r?`n" | Where-Object { $_.Trim() -ne "" -and $_ -notmatch "^total\s+\d+" } | ForEach-Object { $_.Trim() }
}

function Wait-ForCrash {
    param(
        [string[]]$BaselineFault,
        [string[]]$BaselineGwpasan
    )

    $startTime = Get-Date
    $lastPid = $null
    $hasNewCrash = $false
    $hasNewGwpasan = $false
    $crashLogs = @()
    $gwpasanLogs = @()

    Write-Info "开始监控崩溃（检测方式：faultlogger/gwpasan/进程消失/${TimeoutSeconds}s超时）..."

    while ($true) {
        # 检查中断标志
        if ($script:Interrupted) {
            Write-Warn "监控被用户中断"
            return @{ Crashed = $false; Method = "interrupted"; CrashLogs = @(); GwpasanLogs = @() }
        }

        Start-Sleep -Seconds $PollInterval
        $elapsed = (Get-Date) - $startTime

        # 检查新日志
        $currentFault = Get-FaultLoggerFiles | Where-Object { $BaselineFault -notcontains $_ }
        $currentGwpasan = Get-GwpasanFiles | Where-Object { $BaselineGwpasan -notcontains $_ }
        if ($currentFault -and $currentFault.Count -gt 0) {
            $hasNewCrash = $true
            $crashLogs = $currentFault
        }
        if ($currentGwpasan -and $currentGwpasan.Count -gt 0) {
            $hasNewGwpasan = $true
            $gwpasanLogs = $currentGwpasan
        }

        $currentPid = Get-AppPid

        # 进程从有到无 -> 退出/崩溃
        if ($lastPid -and -not $currentPid) {
            Write-Info "检测到应用进程已退出 (原 PID: $lastPid)"
            Start-Sleep -Seconds $PostCrashDelay
            # 最终检查
            $finalFault = Get-FaultLoggerFiles | Where-Object { $BaselineFault -notcontains $_ }
            $finalGwpasan = Get-GwpasanFiles | Where-Object { $BaselineGwpasan -notcontains $_ }
            if ($finalFault -and $finalFault.Count -gt 0) {
                $hasNewCrash = $true
                $crashLogs = $finalFault
            }
            if ($finalGwpasan -and $finalGwpasan.Count -gt 0) {
                $hasNewGwpasan = $true
                $gwpasanLogs = $finalGwpasan
            }

            if ($hasNewCrash -and $hasNewGwpasan) {
                Write-Info "情况2: 进程退出，检测到 crash($($crashLogs.Count)个) + gwpasan($($gwpasanLogs.Count)个) 日志"
                return @{ Crashed = $true; Method = "crash_and_gwpasan"; CrashLogs = $crashLogs; GwpasanLogs = $gwpasanLogs }
            } elseif ($hasNewCrash -and -not $hasNewGwpasan) {
                Write-Info "情况1: 进程退出，检测到 crash($($crashLogs.Count)个) 日志，无 gwpasan 日志"
                return @{ Crashed = $true; Method = "crash_only"; CrashLogs = $crashLogs; GwpasanLogs = @() }
            } elseif (-not $hasNewCrash -and $hasNewGwpasan) {
                Write-Info "进程退出，检测到 gwpasan($($gwpasanLogs.Count)个) 日志，无 crash 日志"
                return @{ Crashed = $true; Method = "gwpasan_only"; CrashLogs = @(); GwpasanLogs = $gwpasanLogs }
            } else {
                Write-Warn "进程退出但未检测到任何日志，视为正常退出"
                return @{ Crashed = $true; Method = "pid_gone_no_logs"; CrashLogs = @(); GwpasanLogs = @() }
            }
        }

        if ($currentPid) {
            $lastPid = $currentPid
        }

        # 应用启动后快速崩溃：从未检测到PID，但已有新日志
        if (-not $currentPid -and ($hasNewCrash -or $hasNewGwpasan)) {
            Write-Info "检测到新日志但进程未运行，可能启动后快速崩溃 (crash=$($crashLogs.Count), gwpasan=$($gwpasanLogs.Count))..."
            Start-Sleep -Seconds $PostCrashDelay
            $finalFault = Get-FaultLoggerFiles | Where-Object { $BaselineFault -notcontains $_ }
            $finalGwpasan = Get-GwpasanFiles | Where-Object { $BaselineGwpasan -notcontains $_ }
            if ($finalFault -and $finalFault.Count -gt 0) {
                $hasNewCrash = $true
                $crashLogs = $finalFault
            }
            if ($finalGwpasan -and $finalGwpasan.Count -gt 0) {
                $hasNewGwpasan = $true
                $gwpasanLogs = $finalGwpasan
            }

            if ($hasNewCrash -and $hasNewGwpasan) {
                Write-Info "情况2: 快速崩溃，检测到 crash($($crashLogs.Count)个) + gwpasan($($gwpasanLogs.Count)个) 日志"
                return @{ Crashed = $true; Method = "crash_and_gwpasan"; CrashLogs = $crashLogs; GwpasanLogs = $gwpasanLogs }
            } elseif ($hasNewCrash) {
                Write-Info "情况1: 快速崩溃，检测到 crash($($crashLogs.Count)个) 日志，无 gwpasan 日志"
                return @{ Crashed = $true; Method = "crash_only"; CrashLogs = $crashLogs; GwpasanLogs = @() }
            } elseif ($hasNewGwpasan) {
                Write-Info "快速崩溃，检测到 gwpasan($($gwpasanLogs.Count)个) 日志，无 crash 日志"
                return @{ Crashed = $true; Method = "gwpasan_only"; CrashLogs = @(); GwpasanLogs = $gwpasanLogs }
            }
        }

        # 5分钟超时检查
        if ($elapsed.TotalSeconds -ge $TimeoutSeconds) {
            if ($hasNewGwpasan -and $currentPid) {
                Write-Warn "情况3: 检测到 GWP-ASan 日志但进程未退出，${TimeoutSeconds}s 超时，强制终止应用"
                Stop-App | Out-Null
                Start-Sleep -Seconds $PostCrashDelay
                $finalFault = Get-FaultLoggerFiles | Where-Object { $BaselineFault -notcontains $_ }
                $finalGwpasan = Get-GwpasanFiles | Where-Object { $BaselineGwpasan -notcontains $_ }
                return @{ Crashed = $true; Method = "gwpasan_only_timeout"; CrashLogs = $finalFault; GwpasanLogs = $finalGwpasan }
            } else {
                Write-Warn "等待超时 (${TimeoutSeconds}s)，未检测到异常"
                return @{ Crashed = $false; Method = "timeout"; CrashLogs = @(); GwpasanLogs = @() }
            }
        }

        # 状态打印
        if ($currentPid) {
            $status = ""
            if ($hasNewGwpasan) { $status += " [GWP-ASan detected]" }
            if ($hasNewCrash) { $status += " [Crash detected]" }
            Write-Host "  应用运行中 (PID: $currentPid)${status}，已运行 $($elapsed.TotalSeconds.ToString('0'))s ..." -ForegroundColor DarkGray
        } else {
            if ($hasNewCrash -or $hasNewGwpasan) {
                $status = ""
                if ($hasNewGwpasan) { $status += " [GWP-ASan detected]" }
                if ($hasNewCrash) { $status += " [Crash detected]" }
                Write-Host "  等待应用启动... 已等待 $($elapsed.TotalSeconds.ToString('0'))s (日志已检测到${status})" -ForegroundColor DarkGray
            } else {
                Write-Host "  等待应用启动... 已等待 $($elapsed.TotalSeconds.ToString('0'))s" -ForegroundColor DarkGray
            }
        }
    }
}

function Collect-FaultLogs {
    param(
        [string]$TargetDir,
        [int]$RunIndex,
        [string[]]$CrashLogs,
        [string[]]$GwpasanLogs
    )

    $collectedCount = 0

    # 1. 收集 crash 日志 (faultlogger)
    $faultLoggerDir = "/data/log/faultlog/faultlogger/"
    if ($CrashLogs -and $CrashLogs.Count -gt 0) {
        Write-Info "收集 crash 日志 ($($CrashLogs.Count) 个)..."
        foreach ($file in $CrashLogs) {
            if ($file -notmatch [regex]::Escape($BundleName)) { continue }
            if ($file.StartsWith("stacktrace")) { continue }
            $remotePath = "$faultLoggerDir$file"
            Write-Info "  拉取 crash 日志: $file"
            $recvResult = Invoke-HdcFileRecv -RemotePath $remotePath -LocalDir $TargetDir
            Write-Host "    $recvResult" -ForegroundColor DarkGray
            $collectedCount++
        }
    } else {
        Write-Info "扫描 crash 日志目录..."
        $files = Invoke-HdcShell -Command "ls -1 $faultLoggerDir 2>/dev/null"
        if (-not [string]::IsNullOrWhiteSpace($files) -and -not ($files -match "No such file")) {
            $fileList = $files -split "`r?`n" | Where-Object { $_.Trim() -ne "" -and $_ -notmatch "^total\s+\d+" -and -not $_.Trim().StartsWith("stacktrace") }
            foreach ($file in $fileList) {
                $file = $file.Trim()
                if ([string]::IsNullOrWhiteSpace($file)) { continue }
                if ($file -notmatch [regex]::Escape($BundleName)) { continue }
                $remotePath = "$faultLoggerDir$file"
                Write-Info "  拉取 crash 日志: $file"
                Invoke-HdcFileRecv -RemotePath $remotePath -LocalDir $TargetDir | Out-Null
                $collectedCount++
            }
        }
    }

    # 2. 收集 GWP-ASan 日志
    if ($GwpasanLogs -and $GwpasanLogs.Count -gt 0) {
        Write-Info "收集 GWP-ASan 日志 ($($GwpasanLogs.Count) 个)..."
        foreach ($file in $GwpasanLogs) {
            $remotePath = "$($script:ActualGwpasanDir)$file"
            Write-Info "  拉取 GWP-ASan 日志: $file"
            Invoke-HdcFileRecv -RemotePath $remotePath -LocalDir $TargetDir | Out-Null
            $collectedCount++
        }
    } else {
        if ($script:ActualGwpasanDir) {
            Write-Info "扫描 GWP-ASan 日志目录..."
            $files = Invoke-HdcShell -Command "ls -1 $($script:ActualGwpasanDir) 2>/dev/null"
            if (-not [string]::IsNullOrWhiteSpace($files) -and -not ($files -match "No such file")) {
                $fileList = $files -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
                foreach ($file in $fileList) {
                    $file = $file.Trim()
                    if ([string]::IsNullOrWhiteSpace($file)) { continue }
                    $remotePath = "$($script:ActualGwpasanDir)$file"
                    Write-Info "  拉取 GWP-ASan 日志: $file"
                    Invoke-HdcFileRecv -RemotePath $remotePath -LocalDir $TargetDir | Out-Null
                    $collectedCount++
                }
            }
        }
    }

    # 3. 导出完整 hilog 作为上下文参考
    $hilogFile = Join-Path $TargetDir "hilog_${RunIndex}.txt"
    Write-Info "  导出完整 hilog 到: $hilogFile"
    $hilogContent = Invoke-HdcShell -Command "hilog -d | tail -n 1000"
    if (-not [string]::IsNullOrWhiteSpace($hilogContent)) {
        $hilogContent | Out-File -FilePath $hilogFile -Encoding UTF8
    }

    # 4. 导出应用状态信息
    $dumpFile = Join-Path $TargetDir "app_dump_${RunIndex}.txt"
    $dumpContent = Invoke-HdcShell -Command "aa dump -a"
    if ($dumpContent) {
        $dumpContent | Out-File -FilePath $dumpFile -Encoding UTF8
    }

    return $collectedCount
}

# ==================== 主循环 ====================

Write-Header "鸿蒙崩溃循环测试开始 [GWP-ASan 恢复模式]"
Write-Info "目标应用: $BundleName/$AbilityName"
Write-Info "启动模式: $LaunchMode"
Write-Info "超时时间: ${TimeoutSeconds}s"
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
            Clear-DeviceLogs
        }

        # 确保应用不在运行
        Stop-App | Out-Null
        Start-Sleep -Seconds 1

        # 记录启动前的日志基准
        $baselineFault = Get-FaultLoggerFiles
        $baselineGwpasan = Get-GwpasanFiles
        Write-Info "启动前基准 - crash日志: $($baselineFault.Count) 个, gwpasan日志: $($baselineGwpasan.Count) 个"

        # 设置 GWP-ASan 属性
        Enable-GwpAsanProp | Out-Null

        # 启动应用
        Start-App | Out-Null
        Start-Sleep -Seconds 3  # 给应用充分启动时间

        # 等待崩溃
        $result = Wait-ForCrash -BaselineFault $baselineFault -BaselineGwpasan $baselineGwpasan
        $crashed = $result.Crashed
        $detectMethod = $result.Method
        $crashLogs = $result.CrashLogs
        $gwpasanLogs = $result.GwpasanLogs

        if ($detectMethod -eq "interrupted") {
            Write-Warn "本轮被用户中断"
            break
        }

        if ($detectMethod -eq "timeout") {
            Write-Warn "本轮未检测到异常，继续下一轮"
            Stop-App | Out-Null
        } elseif ($detectMethod -eq "gwpasan_only_timeout") {
            Write-Info "情况3处理完成: 已强制终止应用并收集日志"
        } elseif (-not $crashed) {
            Write-Warn "本轮异常，继续下一轮"
            Stop-App | Out-Null
        } else {
            Write-Info "检测方式: $detectMethod"
        }

        # 收集日志
        Write-Info "收集日志..."
        $count = Collect-FaultLogs -TargetDir $runLogDir -RunIndex $iteration -CrashLogs $crashLogs -GwpasanLogs $gwpasanLogs
        $totalLogsCollected += $count
        Write-Info "本轮收集到 $count 个日志文件"

        Write-Info "第 $iteration 轮完成"

        # 短暂停，避免过于频繁
        Start-Sleep -Seconds 2
    }
} catch [System.Management.Automation.PipelineStoppedException] {
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
