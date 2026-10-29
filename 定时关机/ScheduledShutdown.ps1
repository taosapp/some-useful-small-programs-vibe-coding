# =====================================================================
#  ScheduledShutdown.ps1  -  定时关机助手（终端版）
#
#  用法：
#    1) 双击同目录下的「启动定时关机.bat」
#    2) 命令行交互：powershell -ExecutionPolicy Bypass -File ScheduledShutdown.ps1
#    3) 直接指定时间：powershell -ExecutionPolicy Bypass -File ScheduledShutdown.ps1 -Time 18:05
#
#  说明：倒计时由本脚本自己执行，只要不关闭本终端窗口就会准时关机；
#        关闭终端窗口或按 Ctrl+C 即可取消本次定时关机。
# =====================================================================
param(
    [Alias('Time')][string]$CliTime = '',
    [switch]$Cancel
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------- 基础函数
function Invoke-Shutdown {
    param([string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Cancel-ScheduledShutdown {
    return (Invoke-Shutdown -Arguments @('/a'))
}

# 解析 "18:05" / "18：05" / "18.05" 形式的 24 小时制时间，返回「今天」的该时刻
function Resolve-ShutdownTarget {
    param([string]$TimeText, [datetime]$BaseTime = (Get-Date))
    if ([string]::IsNullOrWhiteSpace($TimeText)) { return $null }
    if ($TimeText -notmatch '^\s*(\d{1,2})\s*[:\uFF1A.]\s*(\d{1,2})\s*$') { return $null }
    $hh = [int]$Matches[1]
    $mm = [int]$Matches[2]
    if ($hh -gt 23 -or $mm -gt 59) { return $null }
    return $BaseTime.Date.AddHours($hh).AddMinutes($mm)
}

function Format-Remaining {
    param([double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([int][math]::Ceiling($Seconds))
    # 注意：不能用 [int]$ts.TotalHours，PowerShell 的 [int] 转换是四舍五入而非截断，
    # 0.975 小时会被舍成 1 小时，直接取 TimeSpan 的时分秒分量才准确
    return ("{0:00}:{1:00}:{2:00}" -f $ts.Hours, $ts.Minutes, $ts.Seconds)
}

# ------------------------------------------------------------------ 主流程
try {
    Write-Host ''
    Write-Host '=========================================' -ForegroundColor Cyan
    Write-Host '        定时关机助手  (24 小时制)' -ForegroundColor Cyan
    Write-Host '=========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("当前时间：{0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
    Write-Host ''

    # 取消系统层面已存在的定时关机
    if ($Cancel) {
        $code = Cancel-ScheduledShutdown
        if ($code -eq 0) {
            Write-Host '已取消系统层面的定时关机。' -ForegroundColor Yellow
        } else {
            Write-Host '当前没有正在进行的系统定时关机。' -ForegroundColor DarkGray
        }
        exit 0
    }

    # ---------------------------------------------------- 1. 输入关机时间
    $inputText = $CliTime
    if ([string]::IsNullOrWhiteSpace($inputText)) {
        Write-Host '请输入关机时间（24 小时制，例如 18:05）：' -ForegroundColor White
        $inputText = Read-Host '> '
    }

    $now = Get-Date
    $target = Resolve-ShutdownTarget -TimeText $inputText
    if ($null -eq $target) {
        Write-Host ''
        Write-Host '[错误] 时间格式无效，请按 24 小时制输入，例如 18:05' -ForegroundColor Red
        exit 1
    }

    # 填的时间今天已经过去 -> 询问是否安排到明天
    if ($target -le $now) {
        Write-Host ''
        Write-Host ("注意：{0} 今天已经过去了。" -f $target.ToString('HH:mm')) -ForegroundColor Yellow
        $ans = Read-Host '是否安排到明天？(Y/n)'
        if ($ans -match '^[nN]') {
            Write-Host '已取消。' -ForegroundColor Yellow
            exit 0
        }
        $target = $target.AddDays(1)
    }

    # ---------------------------------------------------- 2. 确认关机时间
    Write-Host ''
    Write-Host ("  关机时间：{0}" -f $target.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Green
    Write-Host ("  距离关机：{0}" -f (Format-Remaining ($target - (Get-Date)).TotalSeconds)) -ForegroundColor Green
    Write-Host ''
    $confirm = Read-Host '确认执行定时关机？(Y/n)'
    if ($confirm -match '^[nN]') {
        Write-Host '已取消。' -ForegroundColor Yellow
        exit 0
    }

    # ---------------------------------------------------- 3. 倒计时
    $totalSeconds = ($target - (Get-Date)).TotalSeconds
    Write-Host ''
    Write-Host '已开始倒计时，保持本窗口开启即可准时关机。' -ForegroundColor Cyan
    Write-Host '关闭窗口或按 Ctrl+C 即可取消本次定时关机。' -ForegroundColor DarkGray
    Write-Host ''

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $barWidth = 24
    try {
        while ($true) {
            $left = $totalSeconds - $sw.Elapsed.TotalSeconds
            if ($left -le 0) { break }
            $filled = [int](($sw.Elapsed.TotalSeconds / $totalSeconds) * $barWidth)
            if ($filled -gt $barWidth) { $filled = $barWidth }
            $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))
            $remain = Format-Remaining $left
            Write-Host ("`r  [{0}] {1}  | {2}  | Ctrl+C 取消" -f $bar, $remain, $target.ToString('HH:mm:ss')) -NoNewline
            Start-Sleep -Milliseconds 500
        }
    } catch {
        Write-Host ''
        Write-Host '已取消定时关机。' -ForegroundColor Yellow
        exit 0
    }

    Write-Host ''
    Write-Host ''
    Write-Host '时间到，正在关机……' -ForegroundColor Red
    [void](Invoke-Shutdown -Arguments @('/s', '/t', '0'))
} catch {
    Write-Host ''
    Write-Host ("运行出错：{0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
