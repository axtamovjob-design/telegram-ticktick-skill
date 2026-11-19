param(
    [switch]$ResumeOnly,
    [switch]$CheckOnly,
    [string]$JournalPath = (Join-Path $PSScriptRoot '.jimm'),
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$journal = [IO.Path]::GetFullPath($JournalPath)
$marker = Join-Path $journal 'supervisor-pending.json'
$log = Join-Path $journal 'supervisor.log'

function Test-Completion([string]$report) {
    if (!$report -or !(Test-Path -LiteralPath $report)) { return $false }
    $body = Get-Content -LiteralPath $report -Raw -Encoding utf8
    if ($body -notmatch '(?m)^JIMM_STATUS=COMPLETE\s*$' -or $body -match '(?m)^JIMM_STATUS=INCOMPLETE\s*$') { return $false }
    $messages = Join-Path $journal 'pending-messages.jsonl'
    if (Test-Path -LiteralPath $messages) {
        if (@(Get-Content -LiteralPath $messages -Encoding utf8 | Where-Object { $_.Trim() }).Count -gt 0) { return $false }
    }
    $operations = Join-Path $journal 'pending-operations.json'
    if (Test-Path -LiteralPath $operations) {
        try { $queue = Get-Content -LiteralPath $operations -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $false }
        foreach ($field in 'updates','creates','source_retries') {
            if (!($queue.PSObject.Properties.Name -contains $field)) { return $false }
            if (@($queue.$field).Count -gt 0) { return $false }
        }
    }
    return $true
}

if ($CheckOnly) { if (Test-Completion $ReportPath) { exit 0 } else { exit 1 } }
New-Item -ItemType Directory -Path $journal -Force | Out-Null
if ($ResumeOnly -and !(Test-Path -LiteralPath $marker)) { exit 0 }
$mutex = [Threading.Mutex]::new($false, 'Local\Jimm-Telegram-TickTick-Supervisor')
$owned = $false
try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (!$owned) { exit 0 }
    Set-Content -LiteralPath $marker -Value ('{"started":"' + (Get-Date -Format o) + '"}') -Encoding utf8
    while ($true) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $env:JIMM_REPORT_PATH = Join-Path $journal "supervised-$stamp.md"
        Add-Content -LiteralPath $log -Encoding utf8 -Value "$(Get-Date -Format o) attempt_started $stamp"
        try {
            & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Run-Jimm.ps1')
            $code = $LASTEXITCODE
        } catch {
            $code = -1
            Add-Content -LiteralPath $log -Encoding utf8 -Value "$(Get-Date -Format o) worker_error $($_.Exception.GetType().Name)"
        }
        if ($code -eq 0 -and (Test-Completion $env:JIMM_REPORT_PATH)) {
            Add-Content -LiteralPath $log -Encoding utf8 -Value "$(Get-Date -Format o) completed $stamp"
            Remove-Item -LiteralPath $marker -Force
            exit 0
        }
        Add-Content -LiteralPath $log -Encoding utf8 -Value "$(Get-Date -Format o) incomplete exit=$code report=$stamp retry_in_seconds=300"
        Start-Sleep -Seconds 300
    }
} finally {
    Remove-Item Env:JIMM_REPORT_PATH -ErrorAction SilentlyContinue
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

