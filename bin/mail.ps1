<#
  desktop-agent-mail: почта между чатами Claude desktop и Codex desktop.

  Команды:
    send   -From claude|codex -To claude|codex -Topic "..." (-Body "..." | -BodyFile path)
           [-Box имя] [-Project path] [-ReplyTo id] [-Round n]
    wait   -For claude|codex [-Box имя] [-TimeoutMinutes 720]   ждать письмо, показать, убрать в архив
    inbox  -For claude|codex [-Box имя]                         показать непрочитанные, не трогая

  -Box — отделение конкретного чата Claude (по умолчанию main). Чатов Claude может быть
  несколько, и у каждого своё отделение; ответ Codex приходит в отделение отправителя.
    status                                           настройки и проверка Codex

  Ящик: $env:AGENT_MAIL_HOME или ~/.agent-mail
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, Mandatory = $true)]
  [ValidateSet('send', 'wait', 'inbox', 'status')]
  [string]$Command,
  [ValidateSet('claude', 'codex')][string]$From,
  [ValidateSet('claude', 'codex')][string]$To,
  [ValidateSet('claude', 'codex')][string]$For,
  [string]$Topic,
  [string]$Body,
  [string]$BodyFile,
  [string]$Project,
  [string]$ReplyTo,
  [int]$Round = 1,
  [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Box = 'main',
  [int]$TimeoutMinutes = 720
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Utf8 = New-Object Text.UTF8Encoding($false)

$MailHome = if ($env:AGENT_MAIL_HOME) { $env:AGENT_MAIL_HOME } else { Join-Path $HOME '.agent-mail' }
$ConfigPath = Join-Path $MailHome 'config.json'

function Get-Config {
  $cfg = [ordered]@{ codexChat = 'Почта'; maxRounds = 3 }
  if (Test-Path $ConfigPath) {
    $saved = [IO.File]::ReadAllText($ConfigPath, $Utf8) | ConvertFrom-Json
    foreach ($p in $saved.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
  }
  return $cfg
}

function Get-Dir([string]$name) {
  $d = Join-Path $MailHome $name
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

# Codex desktop кладёт codex.exe в папку с хэшем версии; после обновления она меняется.
function Find-Codex {
  if ($env:AGENT_MAIL_CODEX -and (Test-Path $env:AGENT_MAIL_CODEX)) { return $env:AGENT_MAIL_CODEX }
  $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if (Test-Path $root) {
    $exe = Get-ChildItem -Path $root -Filter 'codex.exe' -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($exe) { return $exe.FullName }
  }
  $cmd = Get-Command codex -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# PowerShell 5.1 искажает кавычки и переносы в аргументах внешних программ,
# поэтому собираем командную строку сами по правилам Windows и запускаем через .NET.
function Format-NativeArg([string]$a) {
  '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Native([string]$exe, [string[]]$argv) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($argv | ForEach-Object { Format-NativeArg $_ }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $Utf8
  $psi.StandardErrorEncoding = $Utf8
  $p = [Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  return @{ Code = $p.ExitCode; Out = $out + $errTask.Result }
}

# codex queue не находит чат по имени, когда чатов много, поэтому ищем номер сами.
# В session_index.jsonl переименование дописывает новую строку: актуально последнее имя.
function Resolve-CodexThread([string]$chat) {
  if ($chat -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $chat }
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
  $index = Join-Path $codexHome 'session_index.jsonl'
  if (-not (Test-Path $index)) { throw "Не найден $index. Укажите в config.json номер чата вместо имени." }
  $names = @{}
  foreach ($line in [IO.File]::ReadAllLines($index, $Utf8)) {
    if (-not $line.Trim()) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    if ($e.id) { $names[$e.id] = $e.thread_name }
  }
  $ids = @($names.Keys | Where-Object { $names[$_] -eq $chat })
  if ($ids.Count -eq 0) { throw "В Codex нет чата «$chat». Создайте его или переименуйте нужный чат." }
  if ($ids.Count -gt 1) { throw "В Codex несколько чатов «$chat»: $($ids -join ', '). Оставьте одно такое имя." }
  return $ids[0]
}

function Read-Letter([string]$path) {
  $text = [IO.File]::ReadAllText($path, $Utf8)
  $meta = @{}
  if ($text -match '(?s)^---\r?\n(.*?)\r?\n---\r?\n') {
    foreach ($line in ($Matches[1] -split '\r?\n')) {
      if ($line -match '^(\w+):\s*(.*)$') { $meta[$Matches[1]] = $Matches[2] }
    }
  }
  return @{ Text = $text; Meta = $meta; Path = $path }
}

function Get-InboxDir([string]$who) {
  if ($who -eq 'claude' -and $Box -ne 'main') { return Get-Dir "inbox\claude\$Box" }
  return Get-Dir "inbox\$who"
}

function Get-Unread([string]$who) {
  $dir = Get-InboxDir $who
  return @(Get-ChildItem -Path $dir -Filter '*.md' -File | Sort-Object Name)
}

function Move-ToArchive([string]$path, [string]$state) {
  $dest = Join-Path (Get-Dir 'archive') ((Split-Path $path -Leaf) -replace '\.md$', ".$state.md")
  # Без перезаписи: [IO.File]::Move атомарен и падает, если письмо уже забрали.
  [IO.File]::Move($path, $dest)
  return $dest
}

function Send-Letter {
  if (-not $From -or -not $To -or -not $Topic) { throw 'send: нужны -From, -To и -Topic' }
  if ($BodyFile) { $script:Body = [IO.File]::ReadAllText((Resolve-Path $BodyFile), $Utf8) }
  if (-not $Body) { throw 'send: нужен -Body или -BodyFile' }
  $cfg = Get-Config

  $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
  $header = @(
    '---'
    "id: $id"
    "from: $From"
    "to: $To"
    "box: $Box"
    "topic: $Topic"
    "project: $Project"
    "round: $Round"
    "reply_to: $ReplyTo"
    "created: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')"
    '---'
  ) -join "`n"
  $letter = $header + "`n" + $Body.Trim() + "`n"

  # Пишем во временный файл и переименовываем, чтобы получатель не прочитал половину письма.
  $inbox = Get-InboxDir $To
  $tmp = Join-Path $inbox "$id.tmp"
  $final = Join-Path $inbox "$id.md"
  [IO.File]::WriteAllText($tmp, $letter, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $final

  if ($To -eq 'codex') {
    $codex = Find-Codex
    if (-not $codex) { throw "Письмо $id лежит в ящике, но codex.exe не найден. Укажите путь в AGENT_MAIL_CODEX." }
    $next = $Round + 1
    $notice = @(
      "Письмо $id от $From. Тема: $Topic. Круг $Round из $($cfg.maxRounds)."
      $(if ($Project) { "Проект: $Project" })
      ''
      $Body.Trim()
      ''
      '---'
      "Действуй по скиллу agent-mail. Ответ: mail.ps1 send -From codex -To $From$(if ($From -eq 'claude') { " -Box $Box" }) -ReplyTo $id -Round $next -Topic ""..."" -BodyFile <файл>"
    ) -join "`n"
    $thread = Resolve-CodexThread $cfg.codexChat
    $r = Invoke-Native $codex @('queue', '--thread', $thread, '--message', $notice)
    if ($r.Code -ne 0) { throw "Письмо $id лежит в ящике, но очередь Codex не приняла его: $($r.Out)" }
    # Успех queue значит «поставлено в очередь», а не «прочитано»: ответ проверяется отдельно.
    Move-ToArchive $final 'queued' | Out-Null
    Write-Output "Поставлено в очередь: $id -> чат Codex «$($cfg.codexChat)»."
  } else {
    Write-Output "Отправлено: $id -> ящик $To/$Box."
  }
}

function Show-Letters([object[]]$files, [bool]$archive) {
  $cfg = Get-Config
  $script:Shown = 0
  foreach ($f in $files) {
    $path = $f.FullName
    if ($archive) {
      # Забираем письмо переносом в архив: перенос атомарный, и если другой ожидающий
      # успел раньше, письмо его, а не наше.
      try { $path = Move-ToArchive $path 'read' } catch { continue }
    }
    $l = Read-Letter $path
    $script:Shown++
    Write-Output "===== ПИСЬМО $($l.Meta['id']) ====="
    Write-Output $l.Text.TrimEnd()
    if ([int]$l.Meta['round'] -ge [int]$cfg.maxRounds) {
      Write-Output "!!! Круг $($l.Meta['round']) из $($cfg.maxRounds): дальше без владельца не отвечать."
    }
  }
}

switch ($Command) {
  'send' { Send-Letter }
  'inbox' {
    if (-not $For) { throw 'inbox: нужен -For' }
    $files = Get-Unread $For
    if ($files.Count -eq 0) { Write-Output 'Писем нет.' } else { Show-Letters $files $false }
  }
  'wait' {
    if (-not $For) { throw 'wait: нужен -For' }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
      $files = Get-Unread $For
      if ($files.Count -gt 0) {
        # Короткая пауза, чтобы забрать и письма, пришедшие пачкой.
        Start-Sleep -Seconds 2
        Show-Letters (Get-Unread $For) $true
        # Если все письма забрал другой ожидающий, ждём дальше, а не будим чат зря.
        if ($script:Shown -gt 0) { exit 0 }
      }
      Start-Sleep -Seconds 2
    }
    Write-Output "Писем не было $TimeoutMinutes мин. Ожидание закончено."
  }
  'status' {
    $cfg = Get-Config
    Write-Output "Ящик:        $MailHome"
    $thread = try { Resolve-CodexThread $cfg.codexChat } catch { "ОШИБКА: $($_.Exception.Message)" }
    Write-Output "Чат Codex:   $($cfg.codexChat) ($thread)"
    Write-Output "Лимит кругов: $($cfg.maxRounds)"
    $codex = Find-Codex
    Write-Output "codex.exe:   $(if ($codex) { $codex } else { 'НЕ НАЙДЕН' })"
    Write-Output "Входящие claude/$Box`: $((Get-Unread 'claude').Count)"
    Write-Output "Входящие codex: $((Get-Unread 'codex').Count)"
  }
}
