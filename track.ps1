Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IconNative {
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
public class DarkTitleBar {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void Apply(IntPtr hwnd) {
        int on = 1;
        if (DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int)) != 0) {
            DwmSetWindowAttribute(hwnd, 19, ref on, sizeof(int));
        }
    }
}
"@

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$gamesPath = Join-Path $root "games.json"
$logsDir = Join-Path $root "logs"
if (!(Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

$traceLogPath = Join-Path $root "tracker.log"
function Write-Trace {
    param([string]$Message)
    try {
        $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Add-Content -Path $traceLogPath -Value $line -Encoding UTF8
    }
    catch {}
}

Write-Trace "啟動 PID=$PID"

$autoStartVbsPath = Join-Path ([Environment]::GetFolderPath('Startup')) "GamePlaytimeTracker.vbs"

function Get-AutoStartEnabled {
    Test-Path $autoStartVbsPath
}

function Set-AutoStart {
    param([bool]$Enable)
    if ($Enable) {
        $trackPath = Join-Path $root "track.ps1"
        $lines = @(
            'Set objShell = CreateObject("WScript.Shell")'
            ('objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""{0}""", 0, False' -f $trackPath)
        )
        Set-Content -Path $autoStartVbsPath -Value $lines -Encoding ASCII
    }
    else {
        if (Test-Path $autoStartVbsPath) { Remove-Item -Path $autoStartVbsPath -Force }
    }
}

$settingsPath = Join-Path $root "settings.json"

function Get-DefaultSettings {
    [PSCustomObject]@{
        PollIntervalMs    = 10000
        SteamEnabled      = $true
        MinSessionSeconds = 5
        ActiveColorHex    = "#2ECC71"
        InactiveColorHex  = "#A0A0A0"
    }
}

function Load-Settings {
    $def = Get-DefaultSettings
    if (Test-Path $settingsPath) {
        try {
            $loaded = Get-Content $settingsPath -Raw | ConvertFrom-Json
            foreach ($prop in $def.PSObject.Properties.Name) {
                if ($null -eq $loaded.$prop) { $loaded | Add-Member -NotePropertyName $prop -NotePropertyValue $def.$prop -Force }
            }
            return $loaded
        }
        catch { return $def }
    }
    return $def
}

function Save-Settings {
    param($Settings)
    $json = ConvertTo-Json -InputObject $Settings -Depth 5
    Set-Content -Path $settingsPath -Value $json -Encoding UTF8
}

$script:settings = Load-Settings

function Save-GamesList {
    param($GamesList)
    $json = ConvertTo-Json -InputObject $GamesList -Depth 5
    Set-Content -Path $gamesPath -Value $json -Encoding UTF8
}

function Reload-Games {
    $script:games = @(Get-Content $gamesPath -Raw | ConvertFrom-Json)
    $currentLabels = @($script:games.label)
    foreach ($label in @($script:state.Keys)) {
        if ($currentLabels -notcontains $label) {
            $st = $script:state[$label]
            if ($st.SessionStart) { Add-SessionLog -Label $label -Start $st.SessionStart -End (Get-Date) }
            $script:state.Remove($label)
        }
    }
    foreach ($g in $script:games) {
        if (-not $script:state.ContainsKey($g.label)) { $script:state[$g.label] = @{ SessionStart = $null } }
    }
}

$games = Get-Content $gamesPath -Raw | ConvertFrom-Json

$state = @{}
foreach ($g in $games) { $state[$g.label] = @{ SessionStart = $null } }

$steamState = @{ SessionStart = $null; AppId = $null; Label = $null }
$script:steamNameCache = @{}

function Get-SteamRunningAppId {
    try {
        $apps = Get-ChildItem -Path "HKCU:\Software\Valve\Steam\Apps" -ErrorAction Stop
        foreach ($app in $apps) {
            $running = (Get-ItemProperty -Path $app.PSPath -Name Running -ErrorAction SilentlyContinue).Running
            if ($running -eq 1) { return [int]$app.PSChildName }
        }
        return 0
    }
    catch {
        return 0
    }
}

function Get-SteamGameName {
    param([int]$AppId)
    if ($script:steamNameCache.ContainsKey($AppId)) { return $script:steamNameCache[$AppId] }
    $name = "Steam($AppId)"
    try {
        $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name SteamPath -ErrorAction Stop).SteamPath
        $manifest = Join-Path $steamPath "steamapps\appmanifest_$AppId.acf"
        if (Test-Path $manifest) {
            $content = Get-Content $manifest -Raw
            if ($content -match '"name"\s+"([^"]+)"') { $name = $Matches[1] }
        }
    }
    catch {}
    $script:steamNameCache[$AppId] = $name
    return $name
}

function Get-TodayCsvPath {
    Join-Path $logsDir ("{0}.csv" -f (Get-Date -Format "yyyy-MM"))
}

function Format-Duration {
    param([int]$Seconds)
    $m = [int][math]::Floor($Seconds / 60)
    if ($m -ge 60) {
        $h = [int][math]::Floor($m / 60)
        $mm = $m % 60
        if ($mm -gt 0) { return "{0}小時{1}分" -f $h, $mm }
        return "{0}小時" -f $h
    }
    return "{0}分" -f $m
}

function Get-AllRows {
    $fileRows = @(Get-ChildItem -Path $logsDir -Filter "*.csv" -ErrorAction SilentlyContinue | ForEach-Object { Import-Csv $_.FullName })
    $now = Get-Date
    $openRows = @()
    foreach ($g in $games) {
        $st = $state[$g.label]
        if ($st.SessionStart) {
            $sec = [int]($now - $st.SessionStart).TotalSeconds
            if ($sec -ge $script:settings.MinSessionSeconds) { $openRows += [PSCustomObject]@{ Date = $st.SessionStart.ToString("yyyy-MM-dd"); Game = $g.label; Seconds = $sec } }
        }
    }
    if ($steamState.SessionStart) {
        $sec = [int]($now - $steamState.SessionStart).TotalSeconds
        if ($sec -ge $script:settings.MinSessionSeconds) { $openRows += [PSCustomObject]@{ Date = $steamState.SessionStart.ToString("yyyy-MM-dd"); Game = $steamState.Label; Seconds = $sec } }
    }
    return @($fileRows) + @($openRows)
}

function Add-SummarySection {
    param($Panel, [string]$Title, $Rows, [ref]$Y, [System.Drawing.Color]$Fore)

    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text = $Title
    $titleLbl.ForeColor = $Fore
    $titleLbl.Font = New-Object System.Drawing.Font("Microsoft JhengHei", 9, [System.Drawing.FontStyle]::Bold)
    $titleLbl.Location = New-Object System.Drawing.Point 10, $Y.Value
    $titleLbl.AutoSize = $true
    $Panel.Controls.Add($titleLbl)
    $Y.Value += 22

    $byGame = @($Rows | Group-Object Game | Sort-Object { ($_.Group | Measure-Object -Property Seconds -Sum).Sum } -Descending)
    if ($byGame.Count -eq 0) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "無紀錄"
        $lbl.ForeColor = $Fore
        $lbl.Font = New-Object System.Drawing.Font("Consolas", 9)
        $lbl.Location = New-Object System.Drawing.Point 24, $Y.Value
        $lbl.AutoSize = $true
        $Panel.Controls.Add($lbl)
        $Y.Value += 24
        return
    }

    foreach ($gg in $byGame) {
        $sec = ($gg.Group | Measure-Object -Property Seconds -Sum).Sum

        $nameLbl = New-Object System.Windows.Forms.Label
        $nameLbl.Text = $gg.Name
        $nameLbl.ForeColor = $Fore
        $nameLbl.Font = New-Object System.Drawing.Font("Consolas", 9)
        $nameLbl.Location = New-Object System.Drawing.Point 24, $Y.Value
        $nameLbl.Size = New-Object System.Drawing.Size 230, 18
        $nameLbl.AutoEllipsis = $true
        $Panel.Controls.Add($nameLbl)

        $durLbl = New-Object System.Windows.Forms.Label
        $durLbl.Text = Format-Duration ([int]$sec)
        $durLbl.ForeColor = $Fore
        $durLbl.Font = New-Object System.Drawing.Font("Consolas", 9)
        $durLbl.TextAlign = 'MiddleRight'
        $durLbl.Location = New-Object System.Drawing.Point 260, $Y.Value
        $durLbl.Size = New-Object System.Drawing.Size 110, 18
        $Panel.Controls.Add($durLbl)

        $Y.Value += 20
    }
    $Y.Value += 10
}

function Get-WeekRange {
    $today = (Get-Date).Date
    $dow = [int]$today.DayOfWeek
    $diffToMonday = if ($dow -eq 0) { 6 } else { $dow - 1 }
    $monday = $today.AddDays(-$diffToMonday)
    return @($monday, $monday.AddDays(6))
}

function Show-DateDetail {
    param($DayGroup, $Owner)
    $d = [datetime]::ParseExact($DayGroup.Name, "yyyy-MM-dd", $null)
    $dateLabel = "{0}/{1}" -f $d.Month, $d.Day

    $detail = New-Object System.Windows.Forms.Form
    $detail.Text = "$dateLabel 遊戲明細"
    $detail.Size = New-Object System.Drawing.Size 340, 320
    $detail.StartPosition = 'CenterParent'
    $detail.TopMost = $true
    $detail.BackColor = [System.Drawing.Color]::FromArgb(255, 24, 24, 24)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Vertical'
    $box.Dock = 'Fill'
    $box.BorderStyle = 'None'
    $box.BackColor = [System.Drawing.Color]::FromArgb(255, 24, 24, 24)
    $box.ForeColor = [System.Drawing.Color]::FromArgb(255, 225, 225, 225)
    $box.Font = New-Object System.Drawing.Font("Consolas", 10)

    $byGame = $DayGroup.Group | Group-Object Game | Sort-Object { ($_.Group | Measure-Object -Property Seconds -Sum).Sum } -Descending
    $lines = foreach ($gg in $byGame) {
        $sec = ($gg.Group | Measure-Object -Property Seconds -Sum).Sum
        "{0,-14} {1}" -f $gg.Name, (Format-Duration ([int]$sec))
    }
    $totalSec = ($DayGroup.Group | Measure-Object -Property Seconds -Sum).Sum
    $lines += ""
    $lines += "總計  $(Format-Duration ([int]$totalSec))"
    $box.Text = $lines -join "`r`n"

    $detail.Controls.Add($box)
    $detail.Add_Shown({ [DarkTitleBar]::Apply($detail.Handle) })
    if ($Owner) { $detail.ShowDialog($Owner) | Out-Null } else { $detail.ShowDialog() | Out-Null }
    $detail.Dispose()
}

function Show-ProcessPicker {
    param($Owner)
    $darkFore = [System.Drawing.Color]::FromArgb(255, 225, 225, 225)
    $darkBack = [System.Drawing.Color]::FromArgb(255, 24, 24, 24)
    $fieldBack = [System.Drawing.Color]::FromArgb(255, 45, 45, 45)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "選擇執行中的程式"
    $dlg.Size = New-Object System.Drawing.Size 420, 480
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $darkBack

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "只列出目前有視窗畫面的程式(遊戲通常會在這裡)"
    $hint.ForeColor = $darkFore
    $hint.Location = New-Object System.Drawing.Point 15, 12
    $hint.AutoSize = $true
    $dlg.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point 15, 36
    $list.Size = New-Object System.Drawing.Size 375, 350
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.GridLines = $true
    $list.BackColor = $fieldBack
    $list.ForeColor = $darkFore
    $list.Columns.Add("視窗標題", 190) | Out-Null
    $list.Columns.Add("Process名稱", 165) | Out-Null

    $procs = Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle.Trim() -ne '' } |
        Sort-Object ProcessName -Unique | Sort-Object MainWindowTitle
    foreach ($p in $procs) {
        $item = New-Object System.Windows.Forms.ListViewItem($p.MainWindowTitle)
        $item.SubItems.Add($p.ProcessName) | Out-Null
        $list.Items.Add($item) | Out-Null
    }
    if ($procs.Count -eq 0) {
        $hint.Text = "目前沒有偵測到有視窗畫面的程式,請先打開要加入的遊戲"
    }
    $dlg.Controls.Add($list)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "選擇"
    $okBtn.Location = New-Object System.Drawing.Point 215, 396
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okBtn.BackColor = $fieldBack
    $okBtn.ForeColor = $darkFore
    $okBtn.FlatStyle = 'Flat'
    $dlg.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "取消"
    $cancelBtn.Location = New-Object System.Drawing.Point 300, 396
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelBtn.BackColor = $fieldBack
    $cancelBtn.ForeColor = $darkFore
    $cancelBtn.FlatStyle = 'Flat'
    $dlg.Controls.Add($cancelBtn)

    $list.add_DoubleClick({ if ($list.SelectedItems.Count -gt 0) { $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() } })

    $dlg.AcceptButton = $okBtn
    $dlg.CancelButton = $cancelBtn
    $dlg.Add_Shown({ [DarkTitleBar]::Apply($dlg.Handle) })

    $result = if ($Owner) { $dlg.ShowDialog($Owner) } else { $dlg.ShowDialog() }
    $output = $null
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedItems.Count -gt 0) {
        $sel = $list.SelectedItems[0]
        $output = @{ Title = $sel.Text; Process = $sel.SubItems[1].Text }
    }
    $dlg.Dispose()
    return $output
}

function Show-GameEditDialog {
    param([string]$Title, [string]$DefaultLabel, [string]$DefaultProcess, $Owner)
    $darkFore = [System.Drawing.Color]::FromArgb(255, 225, 225, 225)
    $darkBack = [System.Drawing.Color]::FromArgb(255, 24, 24, 24)
    $fieldBack = [System.Drawing.Color]::FromArgb(255, 45, 45, 45)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size 300, 260
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $darkBack

    $lbl1 = New-Object System.Windows.Forms.Label
    $lbl1.Text = "顯示名稱"
    $lbl1.ForeColor = $darkFore
    $lbl1.Location = New-Object System.Drawing.Point 20, 18
    $lbl1.AutoSize = $true
    $dlg.Controls.Add($lbl1)

    $box1 = New-Object System.Windows.Forms.TextBox
    $box1.Text = $DefaultLabel
    $box1.Location = New-Object System.Drawing.Point 20, 38
    $box1.Size = New-Object System.Drawing.Size 240, 24
    $box1.BackColor = $fieldBack
    $box1.ForeColor = $darkFore
    $box1.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($box1)

    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text = "Process名稱(工作管理員裡看到的,不含.exe)"
    $lbl2.ForeColor = $darkFore
    $lbl2.Location = New-Object System.Drawing.Point 20, 72
    $lbl2.AutoSize = $true
    $dlg.Controls.Add($lbl2)

    $box2 = New-Object System.Windows.Forms.TextBox
    $box2.Text = $DefaultProcess
    $box2.Location = New-Object System.Drawing.Point 20, 92
    $box2.Size = New-Object System.Drawing.Size 240, 24
    $box2.BackColor = $fieldBack
    $box2.ForeColor = $darkFore
    $box2.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($box2)

    $pickBtn = New-Object System.Windows.Forms.Button
    $pickBtn.Text = "從執行中的程式選擇..."
    $pickBtn.Location = New-Object System.Drawing.Point 20, 122
    $pickBtn.Size = New-Object System.Drawing.Size 240, 26
    $pickBtn.BackColor = $fieldBack
    $pickBtn.ForeColor = $darkFore
    $pickBtn.FlatStyle = 'Flat'
    $pickBtn.add_Click({
        $picked = Show-ProcessPicker -Owner $dlg
        if ($picked) {
            $box2.Text = $picked.Process
            if (-not $box1.Text.Trim()) { $box1.Text = $picked.Title }
        }
    })
    $dlg.Controls.Add($pickBtn)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "確定"
    $okBtn.Location = New-Object System.Drawing.Point 95, 168
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okBtn.BackColor = $fieldBack
    $okBtn.ForeColor = $darkFore
    $okBtn.FlatStyle = 'Flat'
    $dlg.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "取消"
    $cancelBtn.Location = New-Object System.Drawing.Point 180, 168
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelBtn.BackColor = $fieldBack
    $cancelBtn.ForeColor = $darkFore
    $cancelBtn.FlatStyle = 'Flat'
    $dlg.Controls.Add($cancelBtn)

    $dlg.AcceptButton = $okBtn
    $dlg.CancelButton = $cancelBtn
    $dlg.Add_Shown({ [DarkTitleBar]::Apply($dlg.Handle) })

    $result = if ($Owner) { $dlg.ShowDialog($Owner) } else { $dlg.ShowDialog() }
    $output = $null
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $box1.Text.Trim() -and $box2.Text.Trim()) {
        $output = @{ Label = $box1.Text.Trim(); Process = $box2.Text.Trim() }
    }
    $dlg.Dispose()
    return $output
}

function Add-SessionLog {
    param([string]$Label, [datetime]$Start, [datetime]$End)
    $seconds = [int]($End - $Start).TotalSeconds
    if ($seconds -lt $script:settings.MinSessionSeconds) { return }
    $row = [PSCustomObject]@{
        Date    = $Start.ToString("yyyy-MM-dd")
        Game    = $Label
        Start   = $Start.ToString("HH:mm:ss")
        End     = $End.ToString("HH:mm:ss")
        Seconds = $seconds
    }
    $csv = Get-TodayCsvPath
    $row | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
}

function Get-TodayTotals {
    $totals = @{}
    foreach ($g in $games) { $totals[$g.label] = 0 }
    $csv = Get-TodayCsvPath
    $today = Get-Date -Format "yyyy-MM-dd"
    if (Test-Path $csv) {
        Import-Csv $csv | Where-Object { $_.Date -eq $today } | ForEach-Object {
            if (-not $totals.ContainsKey($_.Game)) { $totals[$_.Game] = 0 }
            $totals[$_.Game] += [int]$_.Seconds
        }
    }
    foreach ($g in $games) {
        $s = $state[$g.label].SessionStart
        if ($s) { $totals[$g.label] += [int]((Get-Date) - $s).TotalSeconds }
    }
    if ($steamState.SessionStart) {
        $label = $steamState.Label
        if (-not $totals.ContainsKey($label)) { $totals[$label] = 0 }
        $totals[$label] += [int]((Get-Date) - $steamState.SessionStart).TotalSeconds
    }
    return $totals
}

function New-TrayIcon {
    param([string]$Text, [bool]$Active)
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $color = if ($Active) { [System.Drawing.ColorTranslator]::FromHtml($script:settings.ActiveColorHex) } else { [System.Drawing.ColorTranslator]::FromHtml($script:settings.InactiveColorHex) }
    $fontSize = switch ($Text.Length) {
        1 { 20 }
        2 { 14 }
        default { 10 }
    }
    $font = New-Object System.Drawing.Font("Arial Black", $fontSize, [System.Drawing.FontStyle]::Regular)
    $brush = New-Object System.Drawing.SolidBrush($color)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center

    $g.DrawString($Text, $font, $brush, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $format)

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)

    $font.Dispose()
    $brush.Dispose()
    $g.Dispose()
    $bmp.Dispose()

    return $icon
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$dailyItem = $menu.Items.Add("每日紀錄")
$settingsItem = $menu.Items.Add("設定")
$menu.Items.Add("-") | Out-Null
$exitItem = $menu.Items.Add("結束")
$notifyIcon.ContextMenuStrip = $menu

$settingsItem.add_Click({
    $darkFore = [System.Drawing.Color]::FromArgb(255, 225, 225, 225)
    $darkBack = [System.Drawing.Color]::FromArgb(255, 24, 24, 24)
    $fieldBack = [System.Drawing.Color]::FromArgb(255, 45, 45, 45)
    $dimFore = [System.Drawing.Color]::FromArgb(255, 150, 150, 150)
    $cjkFont = New-Object System.Drawing.Font("Microsoft JhengHei", 9.5)

    $win = New-Object System.Windows.Forms.Form
    $win.Text = "設定"
    $win.Size = New-Object System.Drawing.Size 420, 560
    $win.StartPosition = 'CenterScreen'
    $win.TopMost = $true
    $win.FormBorderStyle = 'FixedDialog'
    $win.MaximizeBox = $false
    $win.MinimizeBox = $false
    $win.BackColor = $darkBack

    # 開機啟動
    $chkAutoStart = New-Object System.Windows.Forms.CheckBox
    $chkAutoStart.Text = "開機時自動啟動"
    $chkAutoStart.ForeColor = $darkFore
    $chkAutoStart.Font = $cjkFont
    $chkAutoStart.Location = New-Object System.Drawing.Point 20, 16
    $chkAutoStart.AutoSize = $true
    $chkAutoStart.Checked = Get-AutoStartEnabled
    $chkAutoStart.add_CheckedChanged({
        Set-AutoStart -Enable $chkAutoStart.Checked
        Write-Trace "設定: 開機啟動 = $($chkAutoStart.Checked)"
    })
    $win.Controls.Add($chkAutoStart)

    # Steam偵測
    $chkSteam = New-Object System.Windows.Forms.CheckBox
    $chkSteam.Text = "偵測 Steam 遊戲"
    $chkSteam.ForeColor = $darkFore
    $chkSteam.Font = $cjkFont
    $chkSteam.Location = New-Object System.Drawing.Point 20, 46
    $chkSteam.AutoSize = $true
    $chkSteam.Checked = [bool]$script:settings.SteamEnabled
    $chkSteam.add_CheckedChanged({
        $script:settings.SteamEnabled = $chkSteam.Checked
        Save-Settings -Settings $script:settings
        Write-Trace "設定: Steam偵測 = $($chkSteam.Checked)"
    })
    $win.Controls.Add($chkSteam)

    # 輪詢間隔
    $lblInterval = New-Object System.Windows.Forms.Label
    $lblInterval.Text = "輪詢間隔"
    $lblInterval.ForeColor = $darkFore
    $lblInterval.Font = $cjkFont
    $lblInterval.Location = New-Object System.Drawing.Point 20, 84
    $lblInterval.AutoSize = $true
    $win.Controls.Add($lblInterval)

    $intervalOptions = @(
        @{ Text = "5 秒"; Ms = 5000 }
        @{ Text = "10 秒"; Ms = 10000 }
        @{ Text = "30 秒"; Ms = 30000 }
        @{ Text = "60 秒"; Ms = 60000 }
    )
    $cmbInterval = New-Object System.Windows.Forms.ComboBox
    $cmbInterval.DropDownStyle = 'DropDownList'
    $cmbInterval.Location = New-Object System.Drawing.Point 140, 80
    $cmbInterval.Size = New-Object System.Drawing.Size 100, 24
    $cmbInterval.BackColor = $fieldBack
    $cmbInterval.ForeColor = $darkFore
    foreach ($opt in $intervalOptions) { $cmbInterval.Items.Add($opt.Text) | Out-Null }
    $selectedIdx = 1
    for ($i = 0; $i -lt $intervalOptions.Count; $i++) {
        if ($intervalOptions[$i].Ms -eq [int]$script:settings.PollIntervalMs) { $selectedIdx = $i; break }
    }
    $cmbInterval.SelectedIndex = $selectedIdx
    $cmbInterval.add_SelectedIndexChanged({
        $ms = $intervalOptions[$cmbInterval.SelectedIndex].Ms
        $script:settings.PollIntervalMs = $ms
        $timer.Interval = $ms
        Save-Settings -Settings $script:settings
        Write-Trace "設定: 輪詢間隔 = ${ms}ms"
    })
    $win.Controls.Add($cmbInterval)

    # 最短紀錄秒數
    $lblMin = New-Object System.Windows.Forms.Label
    $lblMin.Text = "最短紀錄秒數"
    $lblMin.ForeColor = $darkFore
    $lblMin.Font = $cjkFont
    $lblMin.Location = New-Object System.Drawing.Point 20, 122
    $lblMin.AutoSize = $true
    $win.Controls.Add($lblMin)

    $numMin = New-Object System.Windows.Forms.NumericUpDown
    $numMin.Location = New-Object System.Drawing.Point 140, 118
    $numMin.Size = New-Object System.Drawing.Size 80, 24
    $numMin.Minimum = 1
    $numMin.Maximum = 300
    $numMin.BackColor = $fieldBack
    $numMin.ForeColor = $darkFore
    $numMin.Value = [Math]::Max(1, [Math]::Min(300, [int]$script:settings.MinSessionSeconds))
    $numMin.add_ValueChanged({
        $script:settings.MinSessionSeconds = [int]$numMin.Value
        Save-Settings -Settings $script:settings
        Write-Trace "設定: 最短紀錄秒數 = $([int]$numMin.Value)"
    })
    $win.Controls.Add($numMin)

    $hintMin = New-Object System.Windows.Forms.Label
    $hintMin.Text = "(短於這個秒數不紀錄)"
    $hintMin.ForeColor = $dimFore
    $hintMin.Font = $cjkFont
    $hintMin.Location = New-Object System.Drawing.Point 228, 122
    $hintMin.AutoSize = $true
    $win.Controls.Add($hintMin)

    # 圖示顏色
    $lblColor = New-Object System.Windows.Forms.Label
    $lblColor.Text = "圖示顏色"
    $lblColor.ForeColor = $darkFore
    $lblColor.Font = $cjkFont
    $lblColor.Location = New-Object System.Drawing.Point 20, 160
    $lblColor.AutoSize = $true
    $win.Controls.Add($lblColor)

    $btnActiveColor = New-Object System.Windows.Forms.Button
    $btnActiveColor.Text = "使用中"
    $btnActiveColor.Font = $cjkFont
    $btnActiveColor.Location = New-Object System.Drawing.Point 140, 156
    $btnActiveColor.Size = New-Object System.Drawing.Size 100, 28
    $btnActiveColor.FlatStyle = 'Flat'
    $btnActiveColor.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:settings.ActiveColorHex)
    $btnActiveColor.ForeColor = [System.Drawing.Color]::Black
    $btnActiveColor.add_Click({
        $cd = New-Object System.Windows.Forms.ColorDialog
        $cd.Color = $btnActiveColor.BackColor
        if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $btnActiveColor.BackColor = $cd.Color
            $script:settings.ActiveColorHex = [System.Drawing.ColorTranslator]::ToHtml($cd.Color)
            Save-Settings -Settings $script:settings
            Write-Trace "設定: 使用中顏色 = $($script:settings.ActiveColorHex)"
        }
    })
    $win.Controls.Add($btnActiveColor)

    $btnInactiveColor = New-Object System.Windows.Forms.Button
    $btnInactiveColor.Text = "閒置中"
    $btnInactiveColor.Font = $cjkFont
    $btnInactiveColor.Location = New-Object System.Drawing.Point 250, 156
    $btnInactiveColor.Size = New-Object System.Drawing.Size 100, 28
    $btnInactiveColor.FlatStyle = 'Flat'
    $btnInactiveColor.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:settings.InactiveColorHex)
    $btnInactiveColor.ForeColor = [System.Drawing.Color]::Black
    $btnInactiveColor.add_Click({
        $cd = New-Object System.Windows.Forms.ColorDialog
        $cd.Color = $btnInactiveColor.BackColor
        if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $btnInactiveColor.BackColor = $cd.Color
            $script:settings.InactiveColorHex = [System.Drawing.ColorTranslator]::ToHtml($cd.Color)
            Save-Settings -Settings $script:settings
            Write-Trace "設定: 閒置中顏色 = $($script:settings.InactiveColorHex)"
        }
    })
    $win.Controls.Add($btnInactiveColor)

    # 遊戲清單
    $lblGames = New-Object System.Windows.Forms.Label
    $lblGames.Text = "遊戲清單 (Steam遊戲會自動偵測,不用加在這裡)"
    $lblGames.ForeColor = $darkFore
    $lblGames.Font = $cjkFont
    $lblGames.Location = New-Object System.Drawing.Point 20, 202
    $lblGames.AutoSize = $true
    $win.Controls.Add($lblGames)

    $gameList = New-Object System.Windows.Forms.ListView
    $gameList.Location = New-Object System.Drawing.Point 20, 226
    $gameList.Size = New-Object System.Drawing.Size 360, 180
    $gameList.View = 'Details'
    $gameList.FullRowSelect = $true
    $gameList.GridLines = $false
    $gameList.MultiSelect = $false
    $gameList.BackColor = $darkBack
    $gameList.ForeColor = $darkFore
    $gameList.Font = New-Object System.Drawing.Font("Consolas", 9)
    $gameList.Columns.Add("顯示名稱", 140) | Out-Null
    $gameList.Columns.Add("Process名稱", 200) | Out-Null
    $win.Controls.Add($gameList)

    function Refresh-GameList {
        $gameList.Items.Clear()
        foreach ($g in $script:games) {
            $item = New-Object System.Windows.Forms.ListViewItem($g.label)
            $item.SubItems.Add($g.process) | Out-Null
            $gameList.Items.Add($item) | Out-Null
        }
    }
    Refresh-GameList

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "新增"
    $btnAdd.Font = $cjkFont
    $btnAdd.Location = New-Object System.Drawing.Point 20, 414
    $btnAdd.Size = New-Object System.Drawing.Size 80, 28
    $btnAdd.BackColor = $fieldBack
    $btnAdd.ForeColor = $darkFore
    $btnAdd.FlatStyle = 'Flat'
    $btnAdd.add_Click({
        $result = Show-GameEditDialog -Title "新增遊戲" -DefaultLabel "" -DefaultProcess "" -Owner $win
        if ($result) {
            $newList = @($script:games) + [PSCustomObject]@{ label = $result.Label; process = $result.Process }
            Save-GamesList -GamesList $newList
            Reload-Games
            Refresh-GameList
            Write-Trace "設定: 新增遊戲 $($result.Label) / $($result.Process)"
        }
    })
    $win.Controls.Add($btnAdd)

    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = "編輯"
    $btnEdit.Font = $cjkFont
    $btnEdit.Location = New-Object System.Drawing.Point 110, 414
    $btnEdit.Size = New-Object System.Drawing.Size 80, 28
    $btnEdit.BackColor = $fieldBack
    $btnEdit.ForeColor = $darkFore
    $btnEdit.FlatStyle = 'Flat'
    $btnEdit.add_Click({
        if ($gameList.SelectedItems.Count -eq 0) { return }
        $idx = $gameList.SelectedIndices[0]
        $current = $script:games[$idx]
        $result = Show-GameEditDialog -Title "編輯遊戲" -DefaultLabel $current.label -DefaultProcess $current.process -Owner $win
        if ($result) {
            $newList = @($script:games)
            $newList[$idx] = [PSCustomObject]@{ label = $result.Label; process = $result.Process }
            Save-GamesList -GamesList $newList
            Reload-Games
            Refresh-GameList
            Write-Trace "設定: 編輯遊戲 -> $($result.Label) / $($result.Process)"
        }
    })
    $win.Controls.Add($btnEdit)

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "移除"
    $btnRemove.Font = $cjkFont
    $btnRemove.Location = New-Object System.Drawing.Point 200, 414
    $btnRemove.Size = New-Object System.Drawing.Size 80, 28
    $btnRemove.BackColor = $fieldBack
    $btnRemove.ForeColor = $darkFore
    $btnRemove.FlatStyle = 'Flat'
    $btnRemove.add_Click({
        if ($gameList.SelectedItems.Count -eq 0) { return }
        $idx = $gameList.SelectedIndices[0]
        $current = $script:games[$idx]
        $confirm = [System.Windows.Forms.MessageBox]::Show($win, "確定要移除「$($current.label)」嗎?", "確認移除", 'YesNo', 'Question')
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $newList = @($script:games | Where-Object { $_.label -ne $current.label -or $_.process -ne $current.process })
            Save-GamesList -GamesList $newList
            Reload-Games
            Refresh-GameList
            Write-Trace "設定: 移除遊戲 $($current.label)"
        }
    })
    $win.Controls.Add($btnRemove)

    $win.Add_Shown({ [DarkTitleBar]::Apply($win.Handle) })
    $win.ShowDialog() | Out-Null
    $win.Dispose()
})

$dailyItem.add_Click({
    $all = Get-AllRows
    $dateGroups = @()
    if ($all -and @($all).Count -gt 0) {
        $dateGroups = @($all | Group-Object Date | Sort-Object Name -Descending)
    }

    $weekStart, $weekEnd = Get-WeekRange
    $weekRows = $all | Where-Object {
        $d = [datetime]::ParseExact($_.Date, "yyyy-MM-dd", $null)
        $d -ge $weekStart -and $d -le $weekEnd
    }
    $monthPrefix = Get-Date -Format "yyyy-MM"
    $monthRows = $all | Where-Object { $_.Date.StartsWith($monthPrefix) }

    $darkFore = [System.Drawing.Color]::FromArgb(255, 225, 225, 225)
    $darkBack = [System.Drawing.Color]::FromArgb(255, 24, 24, 24)
    $panelBack = [System.Drawing.Color]::FromArgb(255, 32, 32, 32)

    $win = New-Object System.Windows.Forms.Form
    $win.Text = "每日遊戲時數"
    $win.Size = New-Object System.Drawing.Size 520, 560
    $win.StartPosition = 'CenterScreen'
    $win.TopMost = $true
    $win.BackColor = $darkBack

    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = 'Top'
    $topPanel.Height = 190
    $topPanel.BackColor = $panelBack
    $topPanel.AutoScroll = $true

    $y = 8
    Add-SummarySection -Panel $topPanel -Title "本月" -Rows $monthRows -Y ([ref]$y) -Fore $darkFore
    Add-SummarySection -Panel $topPanel -Title "本週" -Rows $weekRows -Y ([ref]$y) -Fore $darkFore

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "雙擊日期看詳細"
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 140, 140)
    $hint.Font = New-Object System.Drawing.Font("Consolas", 8)
    $hint.Dock = 'Bottom'
    $hint.Height = 22
    $hint.TextAlign = 'MiddleCenter'

    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines = $false
    $list.MultiSelect = $false
    $list.BackColor = $darkBack
    $list.ForeColor = $darkFore
    $list.Font = New-Object System.Drawing.Font("Consolas", 10)
    $list.HeaderStyle = 'Nonclickable'
    $list.Columns.Add("日期", 100) | Out-Null
    $list.Columns.Add("當日總時數", 200) | Out-Null

    foreach ($dayGroup in $dateGroups) {
        $d = [datetime]::ParseExact($dayGroup.Name, "yyyy-MM-dd", $null)
        $dateLabel = "{0}/{1}" -f $d.Month, $d.Day
        $totalSec = ($dayGroup.Group | Measure-Object -Property Seconds -Sum).Sum
        $item = New-Object System.Windows.Forms.ListViewItem($dateLabel)
        $item.SubItems.Add((Format-Duration ([int]$totalSec))) | Out-Null
        $item.Tag = $dayGroup
        $list.Items.Add($item) | Out-Null
    }
    if ($list.Items.Count -eq 0) {
        $item = New-Object System.Windows.Forms.ListViewItem("目前還沒有任何紀錄")
        $list.Items.Add($item) | Out-Null
    }

    $list.add_DoubleClick({
        if ($list.SelectedItems.Count -eq 0) { return }
        $dayGroup = $list.SelectedItems[0].Tag
        if (-not $dayGroup) { return }
        Show-DateDetail -DayGroup $dayGroup -Owner $win
    })

    $win.Controls.Add($list)
    $win.Controls.Add($hint)
    $win.Controls.Add($topPanel)
    $win.Add_Shown({ [DarkTitleBar]::Apply($win.Handle) })
    $win.ShowDialog() | Out-Null
    $win.Dispose()
})

$form = New-Object System.Windows.Forms.Form
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Opacity = 0

$script:prevHIcon = [IntPtr]::Zero

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]$script:settings.PollIntervalMs

$exitItem.add_Click({
    Write-Trace "使用者點選「結束」,準備關閉"
    foreach ($g in $games) {
        $st = $state[$g.label]
        if ($st.SessionStart) {
            Add-SessionLog -Label $g.label -Start $st.SessionStart -End (Get-Date)
            $st.SessionStart = $null
        }
    }
    if ($steamState.SessionStart) {
        Add-SessionLog -Label $steamState.Label -Start $steamState.SessionStart -End (Get-Date)
        $steamState.SessionStart = $null
    }
    $timer.Stop()
    $notifyIcon.Visible = $false
    Write-Trace "正常關閉完成"
    [System.Windows.Forms.Application]::Exit()
})

$timer.add_Tick({
  try {
    $anyActive = $false

    foreach ($g in $games) {
        $proc = Get-Process -Name $g.process -ErrorAction SilentlyContinue
        $running = [bool]$proc
        $st = $state[$g.label]

        if ($running -and -not $st.SessionStart) {
            $st.SessionStart = Get-Date
        }
        elseif (-not $running -and $st.SessionStart) {
            Add-SessionLog -Label $g.label -Start $st.SessionStart -End (Get-Date)
            $st.SessionStart = $null
        }

        if ($running) { $anyActive = $true }
    }

    if ($script:settings.SteamEnabled) {
        $runningAppId = Get-SteamRunningAppId
        if ($runningAppId -ne 0) {
            if (-not $steamState.SessionStart -or $steamState.AppId -ne $runningAppId) {
                if ($steamState.SessionStart) {
                    Add-SessionLog -Label $steamState.Label -Start $steamState.SessionStart -End (Get-Date)
                }
                $steamState.AppId = $runningAppId
                $steamState.Label = Get-SteamGameName -AppId $runningAppId
                $steamState.SessionStart = Get-Date
            }
            $anyActive = $true
        }
        elseif ($steamState.SessionStart) {
            Add-SessionLog -Label $steamState.Label -Start $steamState.SessionStart -End (Get-Date)
            $steamState.SessionStart = $null
            $steamState.AppId = $null
            $steamState.Label = $null
        }
    }
    elseif ($steamState.SessionStart) {
        Add-SessionLog -Label $steamState.Label -Start $steamState.SessionStart -End (Get-Date)
        $steamState.SessionStart = $null
        $steamState.AppId = $null
        $steamState.Label = $null
    }

    $totals = Get-TodayTotals
    $totalSeconds = ($totals.Values | Measure-Object -Sum).Sum
    $totalMinutes = [int][math]::Floor($totalSeconds / 60)

    $text = if ($totalMinutes -ge 100) { "$([int][math]::Floor($totalMinutes / 60))h" } else { "$totalMinutes" }

    $newIcon = New-TrayIcon -Text $text -Active $anyActive
    $notifyIcon.Icon = $newIcon
    if ($script:prevHIcon -ne [IntPtr]::Zero) { [IconNative]::DestroyIcon($script:prevHIcon) }
    $script:prevHIcon = $newIcon.Handle

    $knownLabels = @($games.label)
    $extraLabels = $totals.Keys | Where-Object { $knownLabels -notcontains $_ }
    $orderedLabels = $knownLabels + $extraLabels

    $tooltipLines = foreach ($label in $orderedLabels) {
        $sec = if ($totals.ContainsKey($label)) { $totals[$label] } else { 0 }
        $m = [int][math]::Floor($sec / 60)
        "${label}: ${m}分"
    }
    $tip = ($tooltipLines -join " / ")
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + "..." }
    $notifyIcon.Text = $tip
  }
  catch {
    Write-Trace "Tick發生例外: $($_.Exception.Message) | $($_.ScriptStackTrace)"
  }
})

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($exSender, $exArgs)
    Write-Trace "UI執行緒未處理例外: $($exArgs.Exception.Message) | $($exArgs.Exception.StackTrace)"
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($exSender, $exArgs)
    Write-Trace "致命未處理例外(即將結束): $($exArgs.ExceptionObject)"
})

$timer.Start()
Write-Trace "開始輪詢,Interval=$($timer.Interval)ms"
[System.Windows.Forms.Application]::Run($form)
Write-Trace "Application.Run 結束(訊息迴圈已離開)"

