param(
  [string]$Flutter = 'C:\Users\sherl\AppData\Local\NextTransferFlutter\flutter\bin\flutter.bat',
  [int]$TimeoutSeconds = 120,
  [string]$PathPrefix = 'test/'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$output = Join-Path $PSScriptRoot 'compass_schema47_shards'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$files = Get-ChildItem (Join-Path $root 'test') -Recurse -File -Filter '*_test.dart' |
  ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') } |
  Where-Object { $_.StartsWith($PathPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
  Sort-Object
$files | Set-Content (Join-Path $output 'manifest.txt')
$summary = @()
foreach ($file in $files) {
  $safe = ($file -replace '[^A-Za-z0-9._-]', '_')
  $json = Join-Path $output "$safe.json"
  $err = Join-Path $output "$safe.err"
  $command = "cd /d `"$root`" && `"$Flutter`" test `"$file`" --concurrency=1 --reporter json 1> `"$json`" 2> `"$err`""
  $process = Start-Process -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList '/c', $command -WindowStyle Hidden -PassThru
  $finished = $process.WaitForExit($TimeoutSeconds * 1000)
  if (-not $finished) {
    taskkill /PID $process.Id /T /F | Out-Null
    $summary += [pscustomobject]@{file=$file; exitCode=$null; terminalDone=$false; status='timeout'}
    break
  }
  $terminal = $false
  if (Test-Path $json) { $terminal = Select-String -Path $json -SimpleMatch '"type":"done"' -Quiet }
  $summary += [pscustomobject]@{file=$file; exitCode=$process.ExitCode; terminalDone=$terminal; status=if($terminal){'complete'}else{'incomplete'}}
  if (-not $terminal) { break }
}
$summary | ConvertTo-Json | Set-Content (Join-Path $output 'summary.json')
