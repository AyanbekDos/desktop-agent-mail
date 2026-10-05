<#
  Установка desktop-agent-mail.
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-CodexChat "Почта"] [-MaxRounds 3]
#>
param(
  [string]$CodexChat = 'Почта',
  [int]$MaxRounds = 3
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Utf8 = New-Object Text.UTF8Encoding($false)
$src = $PSScriptRoot
$MailHome = if ($env:AGENT_MAIL_HOME) { $env:AGENT_MAIL_HOME } else { Join-Path $HOME '.agent-mail' }

foreach ($d in 'bin', 'inbox\claude', 'inbox\codex', 'archive') {
  New-Item -ItemType Directory -Force -Path (Join-Path $MailHome $d) | Out-Null
}
Copy-Item (Join-Path $src 'bin\mail.ps1') (Join-Path $MailHome 'bin\mail.ps1') -Force

$cfgPath = Join-Path $MailHome 'config.json'
if (-not (Test-Path $cfgPath)) {
  $json = [ordered]@{ codexChat = $CodexChat; maxRounds = $MaxRounds } | ConvertTo-Json
  [IO.File]::WriteAllText($cfgPath, $json, $Utf8)
}

$targets = @(
  @{ From = 'skills\claude\agent-mail'; To = Join-Path $HOME '.claude\skills\agent-mail' },
  @{ From = 'skills\codex\agent-mail';  To = Join-Path $HOME '.codex\skills\agent-mail' }
)
foreach ($t in $targets) {
  New-Item -ItemType Directory -Force -Path $t.To | Out-Null
  Copy-Item (Join-Path $src "$($t.From)\SKILL.md") (Join-Path $t.To 'SKILL.md') -Force
  Write-Output "Скилл: $($t.To)"
}

Write-Output "Ящик: $MailHome"
& (Join-Path $MailHome 'bin\mail.ps1') status
