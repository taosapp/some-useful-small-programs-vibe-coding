# =====================================================================
#  ScheduledReminder.ps1  -  定时提醒助手（Windows 11 通知中心）
#
#  用法：
#    1) 双击同目录下的「启动定时提醒.bat」
#    2) 命令行：powershell -ExecutionPolicy Bypass -File ScheduledReminder.ps1
#    3) 测试通知：powershell -ExecutionPolicy Bypass -File ScheduledReminder.ps1 -TestNotify
#
#  说明：
#    - 提醒数据保存在 %APPDATA%\TaoReminder\reminders.json，重启后依然有效
#    - 后台监控进程独立于界面运行，关掉主窗口不影响提醒
#    - 到点通过 Windows 11 原生 Toast 推送到通知中心
# =====================================================================
param(
    [switch]$Watcher,
    [switch]$TestNotify,
    [switch]$StopWatcher,
    [switch]$SelfTest,
    [switch]$SelfTestAdd,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:DataFile = Join-Path $env:APPDATA 'TaoReminder\reminders.json'
$script:LogFile = Join-Path $env:APPDATA 'TaoReminder\watcher.log'
$script:MutexName = 'Local\TaoReminderWatcher'
$script:MaxLength = 1024
$script:Icon = [System.Drawing.SystemIcons]::Information

function Write-WatcherLog {
    param([string]$Message)
    try {
        $dir = Split-Path $script:LogFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message)
        [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

# ----------------------------------------------------------------- 数据读写
function Get-ReminderStore {
    if (-not (Test-Path $script:DataFile)) {
        return @{ Reminders = New-Object System.Collections.ArrayList; Sound = $true; Popup = $false }
    }
    try {
        $raw = [System.IO.File]::ReadAllText($script:DataFile, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw '空文件' }
        $obj = $raw | ConvertFrom-Json
        $list = New-Object System.Collections.ArrayList
        if ($obj -and $obj.PSObject.Properties['Reminders']) {
            foreach ($r in @($obj.Reminders)) { if ($r) { [void]$list.Add($r) } }
        }
        $snd = $true
        $pop = $false
        if ($obj -and $obj.PSObject.Properties['Sound']) { $snd = [bool]$obj.Sound }
        if ($obj -and $obj.PSObject.Properties['Popup']) { $pop = [bool]$obj.Popup }
        return @{ Reminders = $list; Sound = $snd; Popup = $pop }
    } catch {
        Write-WatcherLog ('数据文件解析失败：' + $_.Exception.Message)
        return @{ Reminders = New-Object System.Collections.ArrayList; Sound = $true; Popup = $false }
    }
}

function Save-ReminderStore {
    param($Store)
    $dir = Split-Path $script:DataFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [pscustomobject]@{
        Reminders = @($Store.Reminders)
        Sound     = [bool]$Store.Sound
        Popup     = [bool]$Store.Popup
    }
    $json = $obj | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:DataFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------- 通知发送
$script:Balloon = $null

function Send-Toast {
    param([string]$Title, [string]$Body)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        $nodes.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $nodes.Item(1).AppendChild($xml.CreateTextNode($Body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid)
        $notifier.Show($toast)
        return $true
    } catch {
        return $false
    }
}

function Send-Balloon {
    param([string]$Title, [string]$Body)
    try {
        if ($null -eq $script:Balloon) {
            $script:Balloon = New-Object System.Windows.Forms.NotifyIcon
            $script:Balloon.Icon = $script:Icon
            $script:Balloon.Visible = $true
        }
        $script:Balloon.BalloonTipTitle = $Title
        $script:Balloon.BalloonTipText = $Body
        $script:Balloon.ShowBalloonTip(15000)
        return $true
    } catch {
        return $false
    }
}

function Play-NotifySound {
    try {
        $wav = Join-Path $env:SystemRoot 'Media\WindowsNotify.wav'
        if (Test-Path $wav) {
            $player = New-Object System.Media.SoundPlayer($wav)
            $player.Play()
        } else {
            [System.Media.SystemSounds]::Exclamation.Play()
        }
    } catch { }
}

function Show-ReminderNotification {
    param([string]$Title, [string]$Body, [bool]$Sound = $true, [bool]$Popup = $false)
    $toastOk = Send-Toast -Title $Title -Body $Body
    if (-not $toastOk) { [void](Send-Balloon -Title $Title -Body $Body) }
    if ($Sound) { Play-NotifySound }
    if ($Popup) {
        [void][System.Windows.Forms.MessageBox]::Show($Body, $Title, 'OK', 'Information')
    }
}

# --------------------------------------------------------------- 后台监控
function Set-ReminderProp {
    param($Target, [string]$Name, $Value)
    # PSCustomObject 不允许直接赋值不存在的属性，必须用 Add-Member 补建
    if ($Target.PSObject.Properties[$Name]) {
        $Target.$Name = $Value
    } else {
        Add-Member -InputObject $Target -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Invoke-DueReminders {
    $store = Get-ReminderStore
    if ($store.Reminders.Count -eq 0) { return }
    $now = Get-Date
    $changed = $false
    foreach ($r in $store.Reminders) {
        if (-not $r) { continue }
        $isNotified = $false
        if ($r.PSObject.Properties['Notified']) { $isNotified = [bool]$r.Notified }
        if ($isNotified) { continue }
        try {
            $fireAt = [datetime]::Parse([string]$r.When)
        } catch { continue }
        if ($fireAt -le $now) {
            Set-ReminderProp -Target $r -Name 'Notified' -Value $true
            Set-ReminderProp -Target $r -Name 'NotifiedAt' -Value $now.ToString('yyyy-MM-dd HH:mm:ss')
            $changed = $true
            Write-WatcherLog ('触发提醒：' + $r.When + ' | ' + $r.Content)
            Show-ReminderNotification -Title ([string]$r.When.Substring(0, 16)) -Body ([string]$r.Content) -Sound $store.Sound -Popup $store.Popup
        }
    }
    if ($changed) { Save-ReminderStore $store }
}

function Start-WatcherProcess {
    $exe = Join-Path $PSHOME 'powershell.exe'
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $PSCommandPath), '-Watcher'
    )
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -PassThru
        return $p
    } catch {
        return $null
    }
}

function Test-WatcherAlive {
    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    try {
        $got = $mutex.WaitOne(0)
        if ($got) { $mutex.ReleaseMutex(); return $false }
        return $true
    } catch {
        return $true
    } finally {
        $mutex.Dispose()
    }
}

# --------------------------------------------------------------- 界面部分
function Show-ReminderGui {
    param([bool]$SelfTestMode = $false, [string]$SelfTestPath = '', [bool]$SelfTestAddMode = $false)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '定时提醒助手'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(620, 490)
    $form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10) } catch { }

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = '定时提醒'
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 14)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(22, 50)
    $lblStatus.Size = New-Object System.Drawing.Size(580, 22)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblStatus)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(20, 78)
    $list.Size = New-Object System.Drawing.Size(580, 280)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.MultiSelect = $true
    $list.HideSelection = $false
    $list.GridLines = $true
    [void]$list.Columns.Add('提醒时间', 150)
    [void]$list.Columns.Add('提醒内容', 330)
    [void]$list.Columns.Add('状态', 80)
    $form.Controls.Add($list)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = '添加提醒'
    $btnAdd.Location = New-Object System.Drawing.Point(20, 370)
    $btnAdd.Size = New-Object System.Drawing.Size(110, 34)
    $form.Controls.Add($btnAdd)

    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text = '删除选中'
    $btnDel.Location = New-Object System.Drawing.Point(140, 370)
    $btnDel.Size = New-Object System.Drawing.Size(110, 34)
    $form.Controls.Add($btnDel)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = '清除已完成'
    $btnClear.Location = New-Object System.Drawing.Point(260, 370)
    $btnClear.Size = New-Object System.Drawing.Size(110, 34)
    $form.Controls.Add($btnClear)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '测试通知'
    $btnTest.Location = New-Object System.Drawing.Point(380, 370)
    $btnTest.Size = New-Object System.Drawing.Size(110, 34)
    $form.Controls.Add($btnTest)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = '退出'
    $btnExit.Location = New-Object System.Drawing.Point(500, 370)
    $btnExit.Size = New-Object System.Drawing.Size(100, 34)
    $form.Controls.Add($btnExit)

    $chkSound = New-Object System.Windows.Forms.CheckBox
    $chkSound.Text = '提醒时播放提示音'
    $chkSound.Location = New-Object System.Drawing.Point(20, 412)
    $chkSound.Size = New-Object System.Drawing.Size(150, 24)
    $form.Controls.Add($chkSound)

    $chkPopup = New-Object System.Windows.Forms.CheckBox
    $chkPopup.Text = '同时弹出模态对话框'
    $chkPopup.Location = New-Object System.Drawing.Point(180, 412)
    $chkPopup.Size = New-Object System.Drawing.Size(170, 24)
    $form.Controls.Add($chkPopup)

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Location = New-Object System.Drawing.Point(360, 412)
    $lblPath.Size = New-Object System.Drawing.Size(240, 24)
    $lblPath.ForeColor = [System.Drawing.Color]::LightSlateGray
    $lblPath.Text = '数据：%APPDATA%\TaoReminder'
    $form.Controls.Add($lblPath)

    $lblTip = New-Object System.Windows.Forms.Label
    $lblTip.Location = New-Object System.Drawing.Point(20, 432)
    $lblTip.Size = New-Object System.Drawing.Size(580, 42)
    $lblTip.ForeColor = [System.Drawing.Color]::DimGray
    $lblTip.Text = '提示：关闭本窗口不会影响提醒，后台监控会继续运行。' + "`r`n" + '如需彻底停止提醒，请运行同目录下的「停止后台监控.bat」。'
    $form.Controls.Add($lblTip)

    # ------------------------------------------------------- 添加提醒对话框
    function Show-AddDialog {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = '添加提醒'
        $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $dlg.ClientSize = New-Object System.Drawing.Size(480, 330)
        $dlg.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
        try { $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10) } catch { }

        $lbl1 = New-Object System.Windows.Forms.Label
        $lbl1.Text = '提醒时间（年-月-日 时:分）'
        $lbl1.Location = New-Object System.Drawing.Point(20, 18)
        $lbl1.Size = New-Object System.Drawing.Size(260, 22)
        $dlg.Controls.Add($lbl1)

        $dtp = New-Object System.Windows.Forms.DateTimePicker
        $dtp.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
        $dtp.CustomFormat = 'yyyy-MM-dd HH:mm'
        $dtp.ShowUpDown = $true
        $dtp.Location = New-Object System.Drawing.Point(20, 44)
        $dtp.Size = New-Object System.Drawing.Size(190, 28)
        # WinForms 的 DateTimePicker 用 MinDate / MaxDate（不是 WPF 的 MinimumDate）
        $dtp.MinDate = (Get-Date).AddMinutes(-1)
        $dtp.Value = (Get-Date).AddHours(1)
        $dlg.Controls.Add($dtp)

        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.Text = '提醒事项（最多 1024 字）'
        $lbl2.Location = New-Object System.Drawing.Point(20, 84)
        $lbl2.Size = New-Object System.Drawing.Size(260, 22)
        $dlg.Controls.Add($lbl2)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(20, 110)
        $txt.Size = New-Object System.Drawing.Size(440, 140)
        $txt.Multiline = $true
        $txt.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $txt.MaxLength = 1024
        $dlg.Controls.Add($txt)

        $lblCount = New-Object System.Windows.Forms.Label
        $lblCount.Location = New-Object System.Drawing.Point(20, 256)
        $lblCount.Size = New-Object System.Drawing.Size(200, 20)
        $lblCount.ForeColor = [System.Drawing.Color]::DimGray
        $lblCount.Text = '0 / 1024'
        $dlg.Controls.Add($lblCount)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = '确定添加'
        $btnOk.Location = New-Object System.Drawing.Point(270, 285)
        $btnOk.Size = New-Object System.Drawing.Size(100, 32)
        $dlg.Controls.Add($btnOk)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = '取消'
        $btnCancel.Location = New-Object System.Drawing.Point(380, 285)
        $btnCancel.Size = New-Object System.Drawing.Size(80, 32)
        $dlg.Controls.Add($btnCancel)

        $txt.Add_TextChanged({
            $lblCount.Text = '{0} / {1}' -f $txt.TextLength, $script:MaxLength
        })

        $result = $null
        $btnOk.Add_Click({
            $content = $txt.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($content)) {
                [void][System.Windows.Forms.MessageBox]::Show('请填写提醒事项。', '提示', 'OK', 'Warning')
                $txt.Focus()
                return
            }
            if ($txt.TextLength -gt $script:MaxLength) {
                [void][System.Windows.Forms.MessageBox]::Show('提醒事项不能超过 1024 字。', '提示', 'OK', 'Warning')
                return
            }
            if ($dtp.Value -le (Get-Date)) {
                [void][System.Windows.Forms.MessageBox]::Show('提醒时间必须晚于当前时间。', '提示', 'OK', 'Warning')
                return
            }
            $script:newReminder = [pscustomobject]@{
                Id       = [guid]::NewGuid().ToString('N')
                When     = $dtp.Value.ToString('yyyy-MM-ddTHH:mm:ss')
                Content  = $content
                Notified = $false
                Created  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            }
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        })
        $btnCancel.Add_Click({
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $dlg.Close()
        })

        $dlg.AcceptButton = $btnOk
        $dlg.CancelButton = $btnCancel

        $script:newReminder = $null
        [void]$dlg.ShowDialog()
        return $script:newReminder
    }

    # ------------------------------------------------------------- 列表刷新
    function Refresh-List {
        $store = Get-ReminderStore
        $list.Items.Clear()
        $pending = 0
        foreach ($r in $store.Reminders) {
            if (-not $r) { continue }
            $isNotified = $false
            if ($r.PSObject.Properties['Notified']) { $isNotified = [bool]$r.Notified }
            if (-not $isNotified) { $pending++ }
            $item = New-Object System.Windows.Forms.ListViewItem($r.When.Replace('T', ' '))
            [void]$item.SubItems.Add([string]$r.Content)
            [void]$item.SubItems.Add($(if ($isNotified) { '已提醒' } else { '待提醒' }))
            if ($isNotified) { $item.ForeColor = [System.Drawing.Color]::LightSlateGray }
            $item.Tag = $r.Id
            [void]$list.Items.Add($item)
        }
        $chkSound.Checked = $store.Sound
        $chkPopup.Checked = $store.Popup
        $alive = Test-WatcherAlive
        $lblStatus.Text = ('当前时间：{0}    待提醒：{1} 条    后台监控：{2}    共 {3} 条' -f `
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $pending, $(if ($alive) { '运行中' } else { '未运行' }), $store.Reminders.Count)
    }

    # --------------------------------------------------------------- 事件
    $btnAdd.Add_Click({
        try {
            $newOne = Show-AddDialog
            if ($null -ne $newOne) {
                $store = Get-ReminderStore
                [void]$store.Reminders.Add($newOne)
                Save-ReminderStore $store
                Refresh-List
                [void][System.Windows.Forms.MessageBox]::Show('提醒已添加，到点会推送到通知中心。', '添加成功', 'OK', 'Information')
            }
        } catch {
            Write-WatcherLog ('添加失败：' + $_.Exception.GetType().Name + ' | ' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace)
            [void][System.Windows.Forms.MessageBox]::Show(('添加失败：' + $_.Exception.Message), '错误', 'OK', 'Error')
        }
    })

    $btnDel.Add_Click({
        try {
            if ($list.SelectedItems.Count -eq 0) {
                [void][System.Windows.Forms.MessageBox]::Show('请先在列表中选择要删除的提醒。', '提示', 'OK', 'Information')
                return
            }
            $ids = @($list.SelectedItems | ForEach-Object { $_.Tag })
            $store = Get-ReminderStore
            $kept = New-Object System.Collections.ArrayList
            foreach ($r in $store.Reminders) {
                if ($r -and ($ids -notcontains $r.Id)) { [void]$kept.Add($r) }
            }
            $store.Reminders = $kept
            Save-ReminderStore $store
            Refresh-List
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('删除失败：' + $_.Exception.Message), '错误', 'OK', 'Error')
        }
    })

    $btnClear.Add_Click({
        try {
            $store = Get-ReminderStore
            $kept = New-Object System.Collections.ArrayList
            foreach ($r in $store.Reminders) {
                if (-not $r) { continue }
                $isNotified = $false
                if ($r.PSObject.Properties['Notified']) { $isNotified = [bool]$r.Notified }
                if (-not $isNotified) { [void]$kept.Add($r) }
            }
            $store.Reminders = $kept
            Save-ReminderStore $store
            Refresh-List
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('清除失败：' + $_.Exception.Message), '错误', 'OK', 'Error')
        }
    })

    $btnTest.Add_Click({
        try {
            Show-ReminderNotification -Title '定时提醒助手（测试）' -Body '这是一条测试通知，说明 Windows 通知中心工作正常。' -Sound $true -Popup $false
            $btnTest.Text = '已发送 ✓'
            Start-Sleep -Milliseconds 1200
            $btnTest.Text = '测试通知'
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('测试失败：' + $_.Exception.Message), '错误', 'OK', 'Error')
        }
    })

    $btnExit.Add_Click({ $form.Close() })

    $chkSound.Add_CheckedChanged({
        $store = Get-ReminderStore
        $store.Sound = $chkSound.Checked
        Save-ReminderStore $store
    })
    $chkPopup.Add_CheckedChanged({
        $store = Get-ReminderStore
        $store.Popup = $chkPopup.Checked
        Save-ReminderStore $store
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $timer.Add_Tick({
        try {
            Refresh-List
            if (-not $SelfTestMode -and -not (Test-WatcherAlive)) { [void](Start-WatcherProcess) }
        } catch { }
    })

    $form.Add_Shown({
        if (-not $SelfTestMode -and -not (Test-WatcherAlive)) { [void](Start-WatcherProcess) }
        Refresh-List
    })

    if ($SelfTestMode) {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        if ($SelfTestAddMode) {
            # 自动化探针：真实点击「添加提醒」，自动填写并提交，异常会写入日志
            $auto = New-Object System.Windows.Forms.Timer
            $auto.Interval = 600
            $script:autoTicks = 0
            $auto.Add_Tick({
                $script:autoTicks++
                $dlg = [System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq '添加提醒' } | Select-Object -First 1
                if ($dlg) {
                    $tb = $dlg.Controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] } | Select-Object -First 1
                    if ($tb) { $tb.Text = '自检自动添加的提醒' }
                    $ok = $dlg.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq '确定添加' }
                    if ($ok) { $auto.Stop(); $ok.PerformClick() }
                } elseif ($script:autoTicks -gt 12) {
                    $auto.Stop()
                }
            })
            $auto.Start()
            Write-WatcherLog '[SELFTEST] 自动点击「添加提醒」开始'
            $btnAdd.PerformClick()
            $auto.Stop()
            Write-WatcherLog ('[SELFTEST] 点击流程结束，当前提醒条数=' + (Get-ReminderStore).Reminders.Count)
            return
        }
        Start-Sleep -Milliseconds 700
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($SelfTestPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.Close()
        return
    }

    [void]$form.ShowDialog()
}

# ------------------------------------------------------------------ 主入口
try {
    if ($StopWatcher) {
        $killed = 0
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            if ([int]$p.ProcessId -eq $PID) { continue }
            $cmd = [string]$p.CommandLine
            if ($cmd -like '*ScheduledReminder.ps1*' -and $cmd -like '*-Watcher*') {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                $killed++
            }
        }
        Write-Host ("已停止 {0} 个后台监控进程。" -f $killed)
        exit 0
    }

    if ($TestNotify) {
        Show-ReminderNotification -Title '定时提醒助手（测试）' -Body '这是一条测试通知，说明 Windows 通知中心工作正常。' -Sound $true -Popup $false
        Write-Host '测试通知已发送。'
        exit 0
    }

    if ($Watcher) {
        $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
        $owned = $false
        try {
            $owned = $mutex.WaitOne(0)
        } catch { }
        if (-not $owned) {
            Write-WatcherLog '已有监控进程在运行，本次退出。'
            exit 0
        }
        Write-WatcherLog '后台监控进程启动。'
        try {
            while ($true) {
                try { Invoke-DueReminders } catch { Write-WatcherLog ('检查异常：' + $_.Exception.Message) }
                Start-Sleep -Seconds 5
            }
        } finally {
            if ($owned) { $mutex.ReleaseMutex() }
        }
    }

    Show-ReminderGui -SelfTestMode ([bool]$SelfTest) -SelfTestPath $OutputPath -SelfTestAddMode ([bool]$SelfTestAdd)
} catch {
    $msg = "定时提醒助手运行出错：`r`n$($_.Exception.Message)"
    [Console]::Error.WriteLine($msg)
    if (-not $SelfTest) {
        try { [void][System.Windows.Forms.MessageBox]::Show($msg, '定时提醒助手', 'OK', 'Error') } catch { }
        exit 1
    }
}
