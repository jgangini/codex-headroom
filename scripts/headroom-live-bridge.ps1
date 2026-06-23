[CmdletBinding()]
param(
  [string]$Port = "COM3",
  [int]$Baud = 115200,
  [int]$IntervalSeconds = 5,
  [int]$Days = 31,
  [int]$HourlyPoints = 744,
  [int]$WeeklyPoints = 12,
  [string]$ApiBase = "http://127.0.0.1:8787",
  [string]$FixturePath,
  [string]$LogPath,
  [string]$ErrorLogPath,
  [switch]$Once,
  [switch]$DryRun,
  [int]$TimeZoneOffsetMinutes = -300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:CurrentTimeZoneOffsetMinutes = 0
$script:SendFrameNow = $false
$script:Culture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-FirstValue {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string[]]$Names,
    $Default = 0
  )

  if ($null -eq $Object) {
    return $Default
  }

  foreach ($name in $Names) {
    $property = $Object.PSObject.Properties[$name]
    if ($null -ne $property -and $null -ne $property.Value) {
      return $property.Value
    }
  }

  return $Default
}

function Convert-ToNumber {
  param($Value, [double]$Default = 0)

  if ($null -eq $Value -or $Value -eq "") {
    return $Default
  }

  try {
    return [double]$Value
  } catch {
    return $Default
  }
}

function Convert-ToUInt {
  param($Value)
  $number = Convert-ToNumber $Value 0
  if ($number -lt 0) {
    return 0
  }
  return [uint32][Math]::Round($number)
}

function Round-Usd {
  param([double]$Value)
  return [Math]::Round($Value, 6)
}

function Normalize-TimeZoneOffset {
  param([int]$Minutes)

  $clamped = [Math]::Min(840, [Math]::Max(-720, $Minutes))
  $remainder = $clamped % 60
  if ($remainder -ne 0) {
    $clamped -= $remainder
  }
  return $clamped
}

function Get-TimeZoneOffset {
  return [TimeSpan]::FromMinutes($script:CurrentTimeZoneOffsetMinutes)
}

function Convert-ToOffsetDateTime {
  param(
    [Parameter(Mandatory = $true)][string]$Timestamp,
    [Parameter(Mandatory = $true)][int]$OffsetMinutes
  )

  $parsed = [System.DateTimeOffset]::MinValue
  $style = [System.Globalization.DateTimeStyles]::RoundtripKind
  if (-not [System.DateTimeOffset]::TryParse($Timestamp, $script:Culture, $style, [ref]$parsed)) {
    throw "invalid timestamp: $Timestamp"
  }

  return $parsed.ToOffset([TimeSpan]::FromMinutes((Normalize-TimeZoneOffset $OffsetMinutes)))
}

function Invoke-HeadroomJson {
  param([string]$Path)

  $uri = "$ApiBase$Path"
  return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
}

function Write-BridgeLog {
  param([string]$Message)
  $line = "[$((Get-Date).ToString("HH:mm:ss"))] $Message"
  if ($LogPath) {
    Add-Content -LiteralPath $LogPath -Value $line
  } else {
    Write-Host $line
  }
}

function Write-BridgeError {
  param([string]$Message)
  $line = "[$((Get-Date).ToString("HH:mm:ss"))] $Message"
  if ($ErrorLogPath) {
    Add-Content -LiteralPath $ErrorLogPath -Value $line
  } else {
    Write-Error $line
  }
}

function Resolve-SerialPort {
  param([string]$RequestedPort)

  $availablePorts = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
  if (-not $availablePorts) {
    throw "No serial ports found."
  }

  if ($RequestedPort -and ($availablePorts -contains $RequestedPort)) {
    return $RequestedPort
  }

  $ch340Ports = @(
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -and
        $_.Name -match "\(COM\d+\)" -and
        (
          $_.PNPDeviceID -match "VID_1A86&PID_7523" -or
          $_.Name -match "CH340" -or
          $_.Name -match "USB-SERIAL"
        )
      } |
      ForEach-Object {
        if ($_.Name -match "\((COM\d+)\)") {
          $matches[1]
        }
      } |
      Where-Object { $_ }
  )

  $resolvedPort = $null
  if ($ch340Ports.Count -eq 1) {
    $resolvedPort = $ch340Ports[0]
  } elseif ($availablePorts.Count -eq 1) {
    $resolvedPort = $availablePorts[0]
  }

  if ($resolvedPort) {
    if ($RequestedPort -and $RequestedPort -ne $resolvedPort) {
      Write-BridgeLog "requested $RequestedPort not found; using $resolvedPort"
    } else {
      Write-BridgeLog "using detected serial port $resolvedPort"
    }
    return $resolvedPort
  }

  $availableText = ($availablePorts -join ", ")
  if ($RequestedPort) {
    throw "Serial port $RequestedPort not found. Available ports: $availableText"
  }
  throw "Could not resolve serial port automatically. Available ports: $availableText"
}

function Convert-HourlyRow {
  param($Point)

  $timestamp = [string](Get-FirstValue $Point @("timestamp", "date", "day") "")
  if ([string]::IsNullOrWhiteSpace($timestamp)) {
    return $null
  }

  $local = Convert-ToOffsetDateTime -Timestamp $timestamp -OffsetMinutes $script:CurrentTimeZoneOffsetMinutes
  return [pscustomobject]@{
    local = $local
    localDate = $local.Date
    localHour = $local.Hour
    savedTokens = Convert-ToUInt (Get-FirstValue $Point @("tokens_saved", "tokens_saved_delta", "total_tokens_saved_delta") 0)
    savedUsd = Round-Usd (Convert-ToNumber (Get-FirstValue $Point @("compression_savings_usd_delta", "compression_savings_usd", "savings_usd") 0) 0)
    inputTokens = Convert-ToUInt (Get-FirstValue $Point @("total_input_tokens_delta", "input_tokens_delta", "total_input_tokens") 0)
    consumedUsd = Round-Usd (Convert-ToNumber (Get-FirstValue $Point @("total_input_cost_usd_delta", "total_input_cost_usd", "cost_usd") 0) 0)
  }
}

function New-ZeroBucket {
  [pscustomobject]@{
    savedTokens = [uint32]0
    savedUsd = 0.0
    inputTokens = [uint32]0
    consumedUsd = 0.0
  }
}

function Add-BucketValues {
  param(
    [Parameter(Mandatory = $true)]$Bucket,
    [Parameter(Mandatory = $true)]$Row
  )

  $Bucket.savedTokens = [uint32]($Bucket.savedTokens + $Row.savedTokens)
  $Bucket.inputTokens = [uint32]($Bucket.inputTokens + $Row.inputTokens)
  $Bucket.savedUsd = Round-Usd ($Bucket.savedUsd + $Row.savedUsd)
  $Bucket.consumedUsd = Round-Usd ($Bucket.consumedUsd + $Row.consumedUsd)
}

function New-SeriesPoint {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)]$Bucket
  )

  [ordered]@{
    label = $Label
    consumed_usd = Round-Usd $Bucket.consumedUsd
    saved_usd = Round-Usd $Bucket.savedUsd
    input_tokens = [uint32]$Bucket.inputTokens
    saved_tokens = [uint32]$Bucket.savedTokens
  }
}

function New-View {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][array]$Series
  )

  [double]$consumed = 0
  [double]$savedUsd = 0
  [uint64]$inputTokens = 0
  [uint64]$savedTokens = 0

  foreach ($point in $Series) {
    $consumed += Convert-ToNumber $point.consumed_usd 0
    $savedUsd += Convert-ToNumber $point.saved_usd 0
    $inputTokens += [uint64](Convert-ToUInt $point.input_tokens)
    $savedTokens += [uint64](Convert-ToUInt $point.saved_tokens)
  }

  $avgPct = 0.0
  if ($consumed -gt 0.0) {
    $avgPct = ($savedUsd / $consumed) * 100.0
  }

  [ordered]@{
    title = $Title
    consumed_usd = Round-Usd $consumed
    saved_usd = Round-Usd $savedUsd
    input_tokens = [uint32]([Math]::Min($inputTokens, [uint64][uint32]::MaxValue))
    saved_tokens = [uint32]([Math]::Min($savedTokens, [uint64][uint32]::MaxValue))
    avg_pct = [Math]::Round($avgPct, 2)
    series = @($Series)
  }
}

function Get-WeekStart {
  param([datetime]$Date)
  $daysSinceMonday = (([int]$Date.DayOfWeek + 6) % 7)
  return $Date.AddDays(-$daysSinceMonday).Date
}

function Build-DayView {
  param([array]$Rows)

  $now = [System.DateTimeOffset]::UtcNow.ToOffset((Get-TimeZoneOffset))
  $today = $now.Date
  $series = @()
  for ($hour = 0; $hour -le $now.Hour; ++$hour) {
    $bucket = New-ZeroBucket
    foreach ($row in $Rows) {
      if ($row.localDate -eq $today -and $row.localHour -eq $hour) {
        Add-BucketValues -Bucket $bucket -Row $row
      }
    }
    $series += New-SeriesPoint -Label ("{0:00}h" -f $hour) -Bucket $bucket
  }

  return New-View -Title "USD by hour" -Series $series
}

function Build-WeekView {
  param([array]$Rows)

  $now = [System.DateTimeOffset]::UtcNow.ToOffset((Get-TimeZoneOffset))
  $today = $now.Date
  $cursor = Get-WeekStart $today
  $series = @()
  while ($cursor -le $today) {
    $bucket = New-ZeroBucket
    foreach ($row in $Rows) {
      if ($row.localDate -eq $cursor) {
        Add-BucketValues -Bucket $bucket -Row $row
      }
    }
    $series += New-SeriesPoint -Label ($cursor.ToString("dd/MM", $script:Culture)) -Bucket $bucket
    $cursor = $cursor.AddDays(1)
  }

  return New-View -Title "USD by day" -Series $series
}

function Get-NextMonthBucketStart {
  param(
    [Parameter(Mandatory = $true)][datetime]$BucketStart,
    [Parameter(Mandatory = $true)][datetime]$MonthStart
  )

  if ($BucketStart -eq $MonthStart) {
    $next = (Get-WeekStart $BucketStart).AddDays(7)
    if ($next -le $BucketStart) {
      $next = $BucketStart.AddDays(7)
    }
    return $next.Date
  }

  return $BucketStart.AddDays(7).Date
}

function Build-MonthView {
  param([array]$Rows)

  $now = [System.DateTimeOffset]::UtcNow.ToOffset((Get-TimeZoneOffset))
  $today = $now.Date
  $monthStart = [datetime]::new($today.Year, $today.Month, 1)
  $rangeEndExclusive = $today.AddDays(1)
  $cursor = $monthStart
  $series = @()

  while ($cursor -lt $rangeEndExclusive) {
    $next = Get-NextMonthBucketStart -BucketStart $cursor -MonthStart $monthStart
    if ($next -gt $rangeEndExclusive) {
      $next = $rangeEndExclusive
    }

    $bucket = New-ZeroBucket
    foreach ($row in $Rows) {
      if ($row.localDate -ge $cursor -and $row.localDate -lt $next) {
        Add-BucketValues -Bucket $bucket -Row $row
      }
    }

    $series += New-SeriesPoint -Label ($cursor.ToString("dd/MM", $script:Culture)) -Bucket $bucket
    $cursor = $next
  }

  return New-View -Title "USD by week" -Series $series
}

function Build-Views {
  param([array]$Rows)

  [ordered]@{
    day = Build-DayView -Rows $Rows
    week = Build-WeekView -Rows $Rows
    month = Build-MonthView -Rows $Rows
  }
}

function ConvertTo-HrmLine {
  param($Frame)
  $json = $Frame | ConvertTo-Json -Depth 12 -Compress
  return "HRM2 $json"
}

function New-HeadroomFrame {
  if ($FixturePath) {
    $fixture = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
    if ($fixture.PSObject.Properties["v"] -and $fixture.v -ge 3) {
      return $fixture
    }
    throw "Fixture must be an HRM2 JSON payload with v>=3."
  }

  $stats = Invoke-HeadroomJson "/stats"
  $hourlyHistory = Invoke-HeadroomJson "/stats-history?series=hourly&history_mode=none"
  $health = Invoke-HeadroomJson "/health"

  $display = $stats.display_session
  $agentTotals = $stats.agent_usage.totals
  $cli = $stats.cli_filtering
  $hourlyRows = @()
  if ($hourlyHistory.series -and $hourlyHistory.series.hourly) {
    $hourlyRows = @(
      $hourlyHistory.series.hourly |
        Select-Object -Last $HourlyPoints |
        ForEach-Object { Convert-HourlyRow $_ } |
        Where-Object { $null -ne $_ }
    )
  }

  [ordered]@{
    v = 3
    ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    ok = [bool](Get-FirstValue $health @("ready", "alive") $false)
    tz_offset_minutes = $script:CurrentTimeZoneOffsetMinutes
    session = [ordered]@{
      req = Convert-ToUInt (Get-FirstValue $display @("requests") (Get-FirstValue $agentTotals @("requests") 0))
      saved = Convert-ToUInt (Get-FirstValue $display @("tokens_saved") (Get-FirstValue $agentTotals @("tokens_saved") 0))
      usd = Round-Usd (Convert-ToNumber (Get-FirstValue $display @("compression_savings_usd") (Get-FirstValue $stats.cost @("compression_savings_usd", "savings_usd") 0)) 0)
      pct = [Math]::Round((Convert-ToNumber (Get-FirstValue $display @("savings_percent") (Get-FirstValue $agentTotals @("savings_percent") 0)) 0), 2)
      input = Convert-ToUInt (Get-FirstValue $display @("total_input_tokens") (Get-FirstValue $stats.tokens @("input") 0))
      last = [string](Get-FirstValue $display @("last_activity_at") "")
    }
    live = [ordered]@{
      rtkCmd = Convert-ToUInt (Get-FirstValue $cli @("total_commands", "lifetime_total_commands") 0)
      rtkSaved = Convert-ToUInt (Get-FirstValue $cli @("tokens_saved", "lifetime_tokens_saved") 0)
      rtkPct = [Math]::Round((Convert-ToNumber (Get-FirstValue $cli @("avg_savings_pct", "lifetime_avg_savings_pct") 0) 0), 2)
      proxy = [string](Get-FirstValue $health @("status") "unknown")
      uptime = Convert-ToUInt (Get-FirstValue $health @("uptime_seconds") 0)
    }
    views = Build-Views -Rows $hourlyRows
  }
}

function Open-SerialPort {
  param([Parameter(Mandatory = $true)][string]$ResolvedPort)

  $serial = [System.IO.Ports.SerialPort]::new($ResolvedPort, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
  $serial.Encoding = [System.Text.Encoding]::ASCII
  $serial.NewLine = "`n"
  $serial.ReadTimeout = 250
  $serial.WriteTimeout = 5000
  $serial.DtrEnable = $false
  $serial.RtsEnable = $false
  $serial.Open()
  return $serial
}

function Close-SerialPort {
  param([ref]$SerialRef)

  if ($null -eq $SerialRef.Value) {
    return
  }

  try {
    if ($SerialRef.Value.IsOpen) {
      $SerialRef.Value.Close()
    }
  } catch {
  }

  try {
    $SerialRef.Value.Dispose()
  } catch {
  }

  $SerialRef.Value = $null
}

function Test-RecoverableSerialException {
  param($Exception)

  if ($null -eq $Exception) {
    return $false
  }

  if (
    $Exception -is [System.IO.IOException] -or
    $Exception -is [System.InvalidOperationException] -or
    $Exception -is [System.TimeoutException] -or
    $Exception -is [System.UnauthorizedAccessException]
  ) {
    return $true
  }

  $message = [string]$Exception.Message
  if (
    $message -match "No serial ports found" -or
    $message -match "Serial port .* not found" -or
    $message -match "Could not resolve serial port automatically" -or
    $message -match "Available ports:" -or
    $message -match "denied" -or
    $message -match "denegado" -or
    $message -match "closed" -or
    $message -match "I/O" -or
    $message -match "port"
  ) {
    return $true
  }

  if ($Exception.InnerException) {
    return Test-RecoverableSerialException -Exception $Exception.InnerException
  }

  return $false
}

function Open-SerialSession {
  param([Parameter(Mandatory = $true)][string]$RequestedPort)

  $resolvedPort = Resolve-SerialPort $RequestedPort
  Write-BridgeLog "opening $resolvedPort at $Baud baud"
  $serial = Open-SerialPort -ResolvedPort $resolvedPort
  Write-BridgeLog "opened $resolvedPort"
  Start-Sleep -Milliseconds 800
  $serial.WriteLine("HRMQ TZ")
  Handle-SerialInput -Serial $serial -MaxLines 20
  $script:SendFrameNow = $true

  return [pscustomobject]@{
    Serial = $serial
    Port = $resolvedPort
  }
}

function Handle-ControlPayload {
  param($Payload)

  if ($null -eq $Payload) {
    return
  }

  $tzValue = $null
  if ($Payload.PSObject.Properties["tz_offset_minutes"]) {
    $tzValue = [int](Convert-ToNumber $Payload.tz_offset_minutes 0)
  } elseif ($Payload.PSObject.Properties["tz"]) {
    $tzValue = [int](Convert-ToNumber $Payload.tz 0)
  }

  if ($null -ne $tzValue) {
    $normalized = Normalize-TimeZoneOffset $tzValue
    if ($normalized -ne $script:CurrentTimeZoneOffsetMinutes) {
      $script:CurrentTimeZoneOffsetMinutes = $normalized
      $script:SendFrameNow = $true
      Write-BridgeLog "timezone updated to UTC$([TimeSpan]::FromMinutes($normalized).ToString()) ($normalized min)"
    }
  }
}

function Handle-SerialInput {
  param(
    [Parameter(Mandatory = $true)][System.IO.Ports.SerialPort]$Serial,
    [int]$MaxLines = 20
  )

  for ($i = 0; $i -lt $MaxLines; ++$i) {
    try {
      $line = $Serial.ReadLine()
    } catch [System.TimeoutException] {
      break
    }

    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $text = $line.Trim()
    if ($text.StartsWith("HRMC ")) {
      try {
        $payload = $text.Substring(5) | ConvertFrom-Json
        Handle-ControlPayload -Payload $payload
      } catch {
        Write-BridgeError "invalid HRMC payload: $text"
      }
      continue
    }

    if ($text.StartsWith("HEADROOM_MONITOR_READY")) {
      $script:SendFrameNow = $true
      Write-BridgeLog "device ready: $text"
      continue
    }
  }
}

function Wait-BridgeInterval {
  param(
    [Parameter(Mandatory = $true)][System.IO.Ports.SerialPort]$Serial,
    [Parameter(Mandatory = $true)][int]$Seconds
  )

  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    Handle-SerialInput -Serial $Serial -MaxLines 8
    if ($script:SendFrameNow) {
      return
    }
    Start-Sleep -Milliseconds 250
  }
}

$script:CurrentTimeZoneOffsetMinutes = Normalize-TimeZoneOffset $TimeZoneOffsetMinutes
$requestedPort = $Port
$resolvedPort = $null
$serialPort = $null
try {
  do {
    if (-not $DryRun -and -not $serialPort) {
      try {
        $session = Open-SerialSession -RequestedPort $requestedPort
        $serialPort = $session.Serial
        $resolvedPort = $session.Port
      } catch {
        if ($Once -or -not $(Test-RecoverableSerialException -Exception $_.Exception)) {
          throw
        }

        Write-BridgeError "serial unavailable: $($_.Exception.Message)"
        Close-SerialPort -SerialRef ([ref]$serialPort)
        $resolvedPort = $null
        Start-Sleep -Seconds 2
        continue
      }
    }

    if (-not $DryRun -and $serialPort) {
      try {
        Handle-SerialInput -Serial $serialPort -MaxLines 20
      } catch {
        if (-not $(Test-RecoverableSerialException -Exception $_.Exception)) {
          throw
        }

        Write-BridgeError "serial read lost on ${resolvedPort}: $($_.Exception.Message)"
        Close-SerialPort -SerialRef ([ref]$serialPort)
        $resolvedPort = $null
        Start-Sleep -Seconds 2
        continue
      }
    }

    try {
      $frame = New-HeadroomFrame
      $line = ConvertTo-HrmLine $frame

      if ($DryRun) {
        $line
      } else {
        $serialPort.WriteLine($line)
        Write-BridgeLog "sent HRM2 v3 frame ($($line.Length) chars, port=$resolvedPort, tz=$script:CurrentTimeZoneOffsetMinutes)"
      }
    } catch {
      if ($Once) {
        throw
      }

      if (-not $DryRun -and $serialPort -and $(Test-RecoverableSerialException -Exception $_.Exception)) {
        Write-BridgeError "serial write lost on ${resolvedPort}: $($_.Exception.Message)"
        Close-SerialPort -SerialRef ([ref]$serialPort)
        $resolvedPort = $null
        Start-Sleep -Seconds 2
        continue
      }

      Write-BridgeError $_.Exception.Message
    }

    if ($Once) {
      break
    }

    $script:SendFrameNow = $false
    if (-not $DryRun -and $serialPort) {
      try {
        Wait-BridgeInterval -Serial $serialPort -Seconds $IntervalSeconds
      } catch {
        if (-not $(Test-RecoverableSerialException -Exception $_.Exception)) {
          throw
        }

        Write-BridgeError "serial wait lost on ${resolvedPort}: $($_.Exception.Message)"
        Close-SerialPort -SerialRef ([ref]$serialPort)
        $resolvedPort = $null
        Start-Sleep -Seconds 2
        continue
      }
    } else {
      Start-Sleep -Seconds $IntervalSeconds
    }
  } while ($true)
} catch {
  Write-BridgeError "fatal: $($_.Exception.Message)"
  throw
} finally {
  Close-SerialPort -SerialRef ([ref]$serialPort)
}
