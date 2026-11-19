param([switch]$Preflight)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$runtime = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies'
$env:JIMM_PYTHON = Join-Path $runtime 'python/python.exe'
$env:PYTHONPATH = Join-Path $root '.venv/Lib/site-packages'
$env:PYTHONDONTWRITEBYTECODE = '1'

$telegramDir = Join-Path $env:LOCALAPPDATA 'CodexTelegram'
if (!(Test-Path -LiteralPath (Join-Path $telegramDir 'account.token'))) {
    $telegramDir = Join-Path $env:LOCALAPPDATA 'Packages/PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0/LocalCache/Local/CodexTelegram'
}
$env:CODEX_TELEGRAM_DATA_DIR = $telegramDir

$codex = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (!$codex) {
    $codex = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin') -Filter codex.exe -Recurse -File |
        Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName -First 1
}
if (!$codex) { throw 'Codex CLI not found.' }

if ($Preflight) {
    $prompt = @'
Run a short read-only Jimm preflight. In PowerShell run & $env:JIMM_PYTHON telegram_access.py check *> $null and check its exit code. Then use that Python and the existing Telethon session to test iter_dialogs(limit=1), printing only whether a dialog is accessible. Do not send read acknowledgements, expose session secrets, or print any chat details. TickTick and Drive must be checked separately. Make no changes to tasks or files. Respond with the two results and a terse reason for any failure.
'@
} else {
    $prompt = Get-Content -LiteralPath (Join-Path $root 'Jimm — единый промпт.md') -Raw -Encoding utf8
    $prompt += @'

Это плановый рабочий запуск Jimm. Расписание уже настроено вне этого процесса. Для Python используй `& $env:JIMM_PYTHON` в PowerShell. Доступ к существующей сессии Telegram задан переменной CODEX_TELEGRAM_DATA_DIR. Используй сохранённую сессию и читай историю через Telethon без отметок о прочтении. Сохраняй контрольные точки и отчёт в `.jimm`. Передвигай контрольную точку только после проверки соответствующих операций в TickTick либо после сохранения фактов, по которым изменений не требуется. Обрабатывай новые сообщения порциями и передавай модели только контекст, необходимый для решений по задачам. При отсутствии доступа к источнику зафиксируй ошибку и продолжи по доступным источникам. Выведи короткий отчёт по-русски без содержимого переписки, секретов и личных данных.
Для записи используй только отдельные операции TickTick create_task, update_task и complete_task. Календарные и массовые операции исключены. Если осталась очередь после сбоя, в начале прохода перечитай актуальный источник и TickTick для одной однозначной операции из очереди, выполни её по правилам промпта и проверь результат чтением. Затем продолжи обычный проход, повторно используй пригодные сохранённые расшифровки и сверяй остальные операции с актуальными данными.
Контроль параллельных запусков выполняет родительский Watch-Jimm.ps1 через системную блокировку. Текущие процессы Watch-Jimm.ps1, Run-Jimm.ps1 и Codex принадлежат этому же проходу: их наличие не означает второй параллельный проход и не является причиной прекращать обработку. Продолжай разбор очереди.
'@
}

$cliArgs = @('exec', '--cd', $root, '--skip-git-repo-check', '--ephemeral', '--sandbox', 'workspace-write', '--add-dir', $telegramDir, '-c', 'sandbox_workspace_write.network_access=true')
if (!$Preflight) {
    $cliArgs += @('--model', 'gpt-6.1-terra', '-c', 'model_reasoning_effort="high"')
    $tickTickApp = 'REPLACE_WITH_TICKTICK_APP_ID'
    if ($tickTickApp -eq 'REPLACE_WITH_TICKTICK_APP_ID') { throw 'Configure the TickTick application ID before a working run.' }
    $tickTickTools = foreach ($operation in 'create_task', 'update_task', 'complete_task') {
        '"ticktick_to_do_list_calendar.{0}" = {{ approval_mode = "approve" }}' -f $operation
        '{0} = {{ approval_mode = "approve" }}' -f $operation
    }
    # CLI config paths split on dots, including dots in quoted tool names.
    $cliArgs += @('-c', ('apps.{0}.tools={{ {1} }}' -f $tickTickApp, ($tickTickTools -join ', ')))
    $journal = Join-Path $root '.jimm'
    New-Item -ItemType Directory -Path $journal -Force | Out-Null
    $report = if ($env:JIMM_REPORT_PATH) { $env:JIMM_REPORT_PATH } else { Join-Path $journal ('run-{0:yyyyMMdd-HHmmss}.md' -f (Get-Date)) }
    $cliArgs += @('--output-last-message', $report)
}

if ($Preflight) {
    $prompt | & $codex @cliArgs '-'
} else {
    $prompt | & $codex @cliArgs '-' *> $null
    $code = $LASTEXITCODE
    if ($code -ne 0) { Add-Content -LiteralPath $report -Value "Codex exit code: $code" -Encoding utf8 }
    exit $code
}
exit $LASTEXITCODE
