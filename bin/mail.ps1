<#
  desktop-agent-mail: почта между чатами Claude desktop и Codex desktop.

  Команды:
    send   -From claude|codex -To claude|codex -Topic "..." (-Body "..." | -BodyFile path)
           [-Project path] [-ReplyTo id] [-Round n]
    wait   -For claude|codex [-TimeoutMinutes 720]   ждать письмо, показать, убрать в архив
    inbox  -For claude|codex                         показать непрочитанные, не трогая
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

function Get-Unread([string]$who) {
  $dir = Get-Dir "inbox\$who"
  return @(Get-ChildItem -Path $dir -Filter '*.md' -File | Sort-Object Name)
}

function Move-ToArchive([string]$path, [string]$state) {
  $dest = Join-Path (Get-Dir 'archive') ((Split-Path $path -Leaf) -replace '\.md$', ".$state.md")
  Move-Item -LiteralPath $path -Destination $dest -Force
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
    "topic: $Topic"
    "project: $Project"
    "round: $Round"
    "reply_to: $ReplyTo"
    "created: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')"
    '---'
  ) -join "`n"
  $letter = $header + "`n" + $Body.Trim() + "`n"

  # Пишем во временный файл и переименовываем, чтобы получатель не прочитал половину письма.
  $inbox = Get-Dir "inbox\$To"
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
      "Действуй по скиллу agent-mail. Ответ: mail.ps1 send -From codex -To $From -ReplyTo $id -Round $next -Topic ""..."" -BodyFile <файл>"
    ) -join "`n"
    # PowerShell 5.1 ломает кавычки внутри аргументов внешних программ.
    $notice = $notice -replace '"', "'"
    $out = & $codex queue --thread $cfg.codexChat --message $notice 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Письмо $id лежит в ящике, но очередь Codex не приняла его: $out" }
    Move-ToArchive $final 'delivered'
    Write-Output "Отправлено: $id -> чат Codex «$($cfg.codexChat)»."
  } else {
    Write-Output "Отправлено: $id -> ящик $To."
  }
}

function Show-Letters([object[]]$files, [bool]$archive) {
  $cfg = Get-Config
  foreach ($f in $files) {
    $l = Read-Letter $f.FullName
    Write-Output "===== ПИСЬМО $($l.Meta['id']) ====="
    Write-Output $l.Text.TrimEnd()
    if ([int]$l.Meta['round'] -ge [int]$cfg.maxRounds) {
      Write-Output "!!! Круг $($l.Meta['round']) из $($cfg.maxRounds): дальше без владельца не отвечать."
    }
    if ($archive) { Move-ToArchive $f.FullName 'read' }
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
        exit 0
      }
      Start-Sleep -Seconds 2
    }
    Write-Output "Писем не было $TimeoutMinutes мин. Ожидание закончено."
  }
  'status' {
    $cfg = Get-Config
    Write-Output "Ящик:        $MailHome"
    Write-Output "Чат Codex:   $($cfg.codexChat)"
    Write-Output "Лимит кругов: $($cfg.maxRounds)"
    $codex = Find-Codex
    Write-Output "codex.exe:   $(if ($codex) { $codex } else { 'НЕ НАЙДЕН' })"
    foreach ($w in 'claude', 'codex') { Write-Output "Входящие $w`: $((Get-Unread $w).Count)" }
  }
}
