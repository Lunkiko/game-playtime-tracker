param(
    [string]$Month = (Get-Date -Format "yyyy-MM")
)

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$csv = Join-Path $root "logs\$Month.csv"

if (!(Test-Path $csv)) {
    Write-Host "尚無 $Month 的紀錄"
    return
}

$rows = Import-Csv $csv
$today = Get-Date -Format "yyyy-MM-dd"

Write-Host "=== 今日 ($today) ==="
$todayRows = $rows | Where-Object { $_.Date -eq $today }
if ($todayRows) {
    $todayRows | Group-Object Game | ForEach-Object {
        $sec = ($_.Group | Measure-Object -Property Seconds -Sum).Sum
        "{0,-8} {1,4} 分 ({2:N1} 小時)" -f $_.Name, [int]($sec / 60), ($sec / 3600)
    }
}
else {
    Write-Host "（今天還沒有紀錄）"
}

Write-Host "`n=== $Month 累計 ==="
$rows | Group-Object Game | ForEach-Object {
    $sec = ($_.Group | Measure-Object -Property Seconds -Sum).Sum
    "{0,-8} {1:N1} 小時" -f $_.Name, ($sec / 3600)
}

