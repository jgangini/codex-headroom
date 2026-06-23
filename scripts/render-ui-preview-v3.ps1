[CmdletBinding()]
param(
  [string]$OutputPath = "outputs\headroom-ui-preview-v3.png",
  [int]$Scale = 2,
  [ValidateSet("DAY", "WEEK", "MONTH", "RANGE", "RANGE_MENU", "WAITING")]
  [string]$Mode = "DAY",
  [switch]$LiveData,
  [string]$TimeZoneLabel = "UTC-05:00"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$script:Scale = [Math]::Max(1, $Scale)

& (Join-Path $PSScriptRoot "render-ui-preview-v3-core.ps1") @PSBoundParameters
return

Add-Type -AssemblyName System.Drawing

function S([double]$Value) { [int][Math]::Round($Value * $script:Scale) }

function New-Color([int]$R, [int]$G, [int]$B) {
  [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function New-Font([string]$Name, [double]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular) {
  [System.Drawing.Font]::new($Name, [single](S $Size), $Style, [System.Drawing.GraphicsUnit]::Pixel)
}

function Draw-RoundRect($Graphics, [System.Drawing.Pen]$Pen, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$R) {
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $d = $R * 2
  $path.AddArc($X, $Y, $d, $d, 180, 90)
  $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
  $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
  $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $Graphics.DrawPath($Pen, $path)
  $path.Dispose()
}

function Fill-RoundRect($Graphics, [System.Drawing.Brush]$Brush, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$R) {
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $d = $R * 2
  $path.AddArc($X, $Y, $d, $d, 180, 90)
  $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
  $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
  $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $Graphics.FillPath($Brush, $path)
  $path.Dispose()
}

function Format-ShortNumber([double]$Value) {
  if ($Value -ge 1000000) { return [string]::Format($culture, "{0:0.0}M", $Value / 1000000) }
  if ($Value -ge 1000) { return [string]::Format($culture, "{0:0.0}k", $Value / 1000) }
  return [string]::Format($culture, "{0:0}", $Value)
}

function Format-Money([double]$Value) {
  if ($Value -ge 1000) { return [string]::Format($culture, '${0:0.0}k', $Value / 1000) }
  return [string]::Format($culture, '${0:0.00}', $Value)
}

function Get-PreviewFrame {
  if (-not $LiveData) {
    return New-FixtureFrame
  }

  $bridge = Join-Path $PSScriptRoot "headroom-live-bridge.ps1"
  if (Test-Path -LiteralPath $bridge) {
    $job = $null
    try {
      $job = Start-Job -ScriptBlock {
        param([string]$BridgePath)
        & $BridgePath -Once -DryRun 2>$null
      } -ArgumentList $bridge
      $finished = Wait-Job -Job $job -Timeout 5
      if ($null -ne $finished) {
        $lines = Receive-Job -Job $job
        foreach ($line in $lines) {
          if (($line -is [string]) -and $line.StartsWith("HRM2 ")) {
            return ($line.Substring(5) | ConvertFrom-Json)
          }
        }
      }
    } catch {
      # Fall through to fixture.
    } finally {
      if ($null -ne $job) {
        if ($job.State -eq "Running") { Stop-Job -Job $job | Out-Null }
        Remove-Job -Job $job -Force | Out-Null
      }
    }
  }

  New-FixtureFrame
}

function New-FixtureFrame {
  $today = Get-Date
  $days = for ($i = 13; $i -ge 0; $i--) {
    $d = $today.AddDays(-$i)
    [pscustomobject]@{
      d = $d.ToString("yyyy-MM-dd", $culture)
      saved = 480000 + ((13 - $i) * 15000)
      usd = 2.41 + ((13 - $i) * 0.08)
      input = 7100000 + ((13 - $i) * 180000)
      cost = 11.20 + ((13 - $i) * 0.17)
    }
  }
  [pscustomobject]@{
    ok = $true
    ts = (Get-Date).ToUniversalTime().ToString("s", $culture) + "Z"
    session = [pscustomobject]@{ req = 122; saved = 56935; usd = 0.28; pct = 0.59; input = 9633040; last = "" }
    live = [pscustomobject]@{ rtkCmd = 3; rtkSaved = 704; rtkPct = 20.8; proxy = "fixture"; uptime = 4693 }
    days = @($days)
    chart = [pscustomobject]@{
      hourly = @(
        [pscustomobject]@{ t = $today.Date.AddHours(0).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 14.5 },
        [pscustomobject]@{ t = $today.Date.AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 9.3 },
        [pscustomobject]@{ t = $today.Date.AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 10.8 },
        [pscustomobject]@{ t = $today.Date.AddHours(3).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 14.7 },
        [pscustomobject]@{ t = $today.Date.AddHours(4).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 15.8 },
        [pscustomobject]@{ t = $today.Date.AddHours(5).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 13.6 },
        [pscustomobject]@{ t = $today.Date.AddHours(6).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 11.9 },
        [pscustomobject]@{ t = $today.Date.AddHours(7).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 9.8 },
        [pscustomobject]@{ t = $today.Date.AddHours(8).ToString("yyyy-MM-ddTHH:mm:ss", $culture); cost = 7.1 }
      )
      weekly = @(
        [pscustomobject]@{ t = $today.AddDays(-21).ToString("yyyy-MM-dd", $culture); cost = 42.0 },
        [pscustomobject]@{ t = $today.AddDays(-14).ToString("yyyy-MM-dd", $culture); cost = 58.0 },
        [pscustomobject]@{ t = $today.AddDays(-7).ToString("yyyy-MM-dd", $culture); cost = 36.0 },
        [pscustomobject]@{ t = $today.ToString("yyyy-MM-dd", $culture); cost = 64.0 }
      )
    }
  }
}

function Get-Aggregate($Frame, [string]$PeriodMode) {
  $days = @($Frame.days)
  if ($days.Count -eq 0) {
    return [pscustomobject]@{ saved = 0.0; usd = 0.0; input = 0.0; cost = 0.0; days = @() }
  }

  $end = $days.Count - 1
  $start = $end
  if ($PeriodMode -eq "WEEK") {
    $start = [Math]::Max(0, $end - 6)
  } elseif ($PeriodMode -eq "MONTH") {
    $prefix = ([string]$days[$end].d).Substring(0, 7)
    while (($start -gt 0) -and (([string]$days[$start - 1].d).StartsWith($prefix))) { $start-- }
  } elseif ($PeriodMode -eq "RANGE") {
    $start = [Math]::Max(0, $end - 13)
  }

  $slice = @($days[$start..$end])
  $agg = [pscustomobject]@{ saved = 0.0; usd = 0.0; input = 0.0; cost = 0.0; days = $slice }
  foreach ($day in $slice) {
    $agg.saved += [double]$day.saved
    $agg.usd += [double]$day.usd
    $agg.input += [double]$day.input
    $agg.cost += [double]$day.cost
  }
  $agg
}

function Get-ChartStep([double]$MaxValue) {
  $rawStep = $MaxValue / 5.0
  if ($rawStep -le 5.0) { return 5.0 }

  $magnitude = 1.0
  while ($rawStep -gt 50.0) {
    $rawStep /= 10.0
    $magnitude *= 10.0
  }

  if ($rawStep -le 10.0) { return 10.0 * $magnitude }
  if ($rawStep -le 20.0) { return 20.0 * $magnitude }
  if ($rawStep -le 25.0) { return 25.0 * $magnitude }
  return 50.0 * $magnitude
}

function Get-ChartTop([double]$MaxValue) {
  $step = Get-ChartStep $MaxValue
  $top = [Math]::Ceiling($MaxValue / $step) * $step
  if ($top -lt $step) { $top = $step }
  return $top
}

function Get-ChartPoints($Frame, [string]$PeriodMode) {
  $days = @($Frame.days)
  if ($days.Count -eq 0) { return @() }

  $selectedDate = [string]$days[-1].d
  $selectedMonth = if ($selectedDate.Length -ge 7) { $selectedDate.Substring(0, 7) } else { $selectedDate }
  $chart = $Frame.chart

  if ($PeriodMode -eq "DAY") {
    $hourly = @()
    if ($null -ne $chart -and $null -ne $chart.hourly) {
      $hourly = @($chart.hourly | Where-Object { ([string]$_.t).StartsWith($selectedDate) })
      if ($hourly.Count -eq 0) { $hourly = @($chart.hourly | Select-Object -Last 24) }
    }
    if ($hourly.Count -gt 0) {
      return @($hourly | ForEach-Object {
        [pscustomobject]@{
          t = [string]$_.t
          cost = [double]$_.cost
        }
      })
    }
  }

  if ($PeriodMode -eq "WEEK") {
    $start = [Math]::Max(0, $days.Count - 7)
    return @($days[$start..($days.Count - 1)] | ForEach-Object {
      [pscustomobject]@{
        t = [string]$_.d
        cost = [double]$_.cost
      }
    })
  }

  $weekly = @()
  if ($null -ne $chart -and $null -ne $chart.weekly) {
    $weekly = @($chart.weekly | Where-Object { ([string]$_.t).StartsWith($selectedMonth) })
    if ($weekly.Count -eq 0) { $weekly = @($chart.weekly | Select-Object -Last 6) }
  }
  if ($weekly.Count -gt 0) {
    return @($weekly | ForEach-Object {
      [pscustomobject]@{
        t = [string]$_.t
        cost = [double]$_.cost
      }
    })
  }

  return @($days | Select-Object -Last 4 | ForEach-Object {
    [pscustomobject]@{
      t = [string]$_.d
      cost = [double]$_.cost
    }
  })
}

function Get-ChartTitle([string]$PeriodMode) {
  if ($PeriodMode -eq "DAY") { return "USD by hour" }
  if ($PeriodMode -eq "WEEK") { return "USD by day" }
  return "USD by week"
}

function Format-ChartXLabel([string]$Timestamp, [string]$PeriodMode) {
  if ([string]::IsNullOrWhiteSpace($Timestamp)) { return "" }
  if ($PeriodMode -eq "DAY" -and $Timestamp.Length -ge 13) {
    return $Timestamp.Substring(11, 2) + "h"
  }
  if ($Timestamp.Length -ge 10) {
    return $Timestamp.Substring(8, 2) + "/" + $Timestamp.Substring(5, 2)
  }
  return $Timestamp
}

function Get-TimeZoneValue([string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Label)) { return "-5" }
  if ($Label -match '^UTC([+-])(\d{2}):(\d{2})$') {
    $sign = $matches[1]
    $hours = [int]$matches[2]
    $minutes = [int]$matches[3]
    if ($minutes -eq 0) { return "$sign$hours" }
    return "$sign$hours.$([int](($minutes * 10) / 60))"
  }
  return $Label
}

function Draw-StepperButton($Graphics, [int]$X, [int]$Y, [bool]$Plus) {
  $whitePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, (S 1))
  $Graphics.DrawRectangle($whitePen, (S $X), (S $Y), (S 18), (S 18))
  $Graphics.DrawLine($whitePen, (S ($X + 5)), (S ($Y + 9)), (S ($X + 13)), (S ($Y + 9)))
  if ($Plus) {
    $Graphics.DrawLine($whitePen, (S ($X + 9)), (S ($Y + 5)), (S ($X + 9)), (S ($Y + 13)))
  }
  $whitePen.Dispose()
}

function Draw-ValueRow($Graphics, [int]$Y, [string]$Label, [string]$Value, [System.Drawing.Color]$Accent) {
  $pen = [System.Drawing.Pen]::new($Accent, (S 1))
  $accentBrush = [System.Drawing.SolidBrush]::new($Accent)
  $whiteBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $font = New-Font "Segoe UI" 12
  $small = New-Font "Segoe UI" 8
  $Graphics.DrawRectangle($pen, (S 8), (S $Y), (S 304), (S 24))
  $Graphics.DrawString($Label, $font, $accentBrush, (S 14), (S ($Y + 4)))
  Draw-StepperButton $Graphics 238 ($Y + 3) $false
  $Graphics.DrawRectangle($pen, (S 260), (S ($Y + 3)), (S 28), (S 18))
  Draw-CenteredText $Graphics $Value $small $whiteBrush 274 ($Y + 12)
  Draw-StepperButton $Graphics 292 ($Y + 3) $true
  $pen.Dispose(); $accentBrush.Dispose(); $whiteBrush.Dispose(); $font.Dispose(); $small.Dispose()
}

function Draw-TimeZoneCombo($Graphics, [int]$Y, [string]$Value) {
  $cyan = [System.Drawing.Color]::FromArgb(0,255,255)
  $comboBg = [System.Drawing.Color]::FromArgb(16,16,16)
  $pen = [System.Drawing.Pen]::new($cyan, (S 1))
  $whitePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, (S 1))
  $cyanBrush = [System.Drawing.SolidBrush]::new($cyan)
  $whiteBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $comboBrush = [System.Drawing.SolidBrush]::new($comboBg)
  $font = New-Font "Segoe UI" 12
  $small = New-Font "Segoe UI" 8
  $Graphics.DrawRectangle($pen, (S 8), (S $Y), (S 304), (S 24))
  $Graphics.DrawString("Timezone", $font, $cyanBrush, (S 14), (S ($Y + 4)))
  $Graphics.FillRectangle($comboBrush, (S 170), (S ($Y + 3)), (S 134), (S 18))
  $Graphics.DrawRectangle($whitePen, (S 170), (S ($Y + 3)), (S 134), (S 18))
  $Graphics.DrawString($Value, $small, $whiteBrush, (S 176), (S ($Y + 6)))
  $Graphics.DrawLine($whitePen, (S 286), (S ($Y + 9)), (S 294), (S ($Y + 9)))
  $Graphics.DrawLine($whitePen, (S 288), (S ($Y + 11)), (S 290), (S ($Y + 13)))
  $Graphics.DrawLine($whitePen, (S 292), (S ($Y + 11)), (S 290), (S ($Y + 13)))
  $pen.Dispose(); $whitePen.Dispose(); $cyanBrush.Dispose(); $whiteBrush.Dispose(); $comboBrush.Dispose(); $font.Dispose(); $small.Dispose()
}

function Draw-TimeZoneMenuOverlay($Graphics, [string]$Value) {
  $panelBg = [System.Drawing.Color]::Black
  $menuBg = [System.Drawing.Color]::FromArgb(8, 20, 28)
  $muted = [System.Drawing.SolidBrush]::new((New-Color 145 145 145))
  $whiteBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $panelBrush = [System.Drawing.SolidBrush]::new($panelBg)
  $menuBrush = [System.Drawing.SolidBrush]::new($menuBg)
  $panelPen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, (S 1))
  $menuPen = [System.Drawing.Pen]::new((New-Color 55 55 55), (S 1))
  $selectedPen = [System.Drawing.Pen]::new((New-Color 0 255 255), (S 1))
  $selectedBrush = [System.Drawing.SolidBrush]::new((New-Color 18 28 28))
  $small = New-Font "Segoe UI" 8

  $Graphics.FillRectangle($panelBrush, (S 8), (S 94), (S 304), (S 128))
  $Graphics.DrawRectangle($panelPen, (S 8), (S 94), (S 304), (S 128))
  $Graphics.DrawString("Select timezone", $small, $muted, (S 16), (S 100))

  $rows = @("PREV", $Value, "UTC-04:00", "UTC-03:00", "UTC-02:00", "NEXT")
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $rowY = 112 + ($i * 18)
    $brush = if ($i -eq 1) { $selectedBrush } else { $menuBrush }
    $pen = if ($i -eq 1) { $selectedPen } else { $menuPen }
    $textBrush = if ($i -eq 1) { [System.Drawing.SolidBrush]::new((New-Color 0 255 255)) } else { $whiteBrush }
    $Graphics.FillRectangle($brush, (S 14), (S $rowY), (S 292), (S 18))
    $Graphics.DrawRectangle($pen, (S 14), (S $rowY), (S 292), (S 18))
    Draw-CenteredText $Graphics $rows[$i] $small $textBrush 160 ($rowY + 9)
    if ($i -eq 1) { $textBrush.Dispose() }
  }

  $muted.Dispose(); $whiteBrush.Dispose(); $panelBrush.Dispose(); $menuBrush.Dispose()
  $panelPen.Dispose(); $menuPen.Dispose(); $selectedPen.Dispose(); $selectedBrush.Dispose(); $small.Dispose()
}

function Draw-AlertIndicator($Graphics, [int]$X, [int]$Y, [System.Drawing.Color]$Color) {
  $outer = [System.Drawing.Pen]::new($Color, (S 1))
  $ring = [System.Drawing.Pen]::new((New-Color 32 32 32), (S 1))
  $fill = [System.Drawing.SolidBrush]::new($Color)
  $Graphics.DrawEllipse($ring, (S ($X - 6)), (S ($Y - 6)), (S 12), (S 12))
  $Graphics.DrawEllipse($outer, (S ($X - 5)), (S ($Y - 5)), (S 10), (S 10))
  $Graphics.FillEllipse($fill, (S ($X - 4)), (S ($Y - 4)), (S 8), (S 8))
  $outer.Dispose(); $ring.Dispose(); $fill.Dispose()
}

function Draw-ThresholdRow($Graphics, [int]$Y, [string]$Label, [string]$Range, [System.Drawing.Color]$Accent, [string]$Value, [bool]$Editable) {
  $pen = [System.Drawing.Pen]::new($Accent, (S 1))
  $accentBrush = [System.Drawing.SolidBrush]::new($Accent)
  $whiteBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $font = New-Font "Segoe UI" 12
  $small = New-Font "Segoe UI" 8
  $Graphics.DrawRectangle($pen, (S 8), (S $Y), (S 304), (S 24))
  $Graphics.DrawString($Label, $font, $accentBrush, (S 14), (S ($Y + 4)))
  $Graphics.DrawString($Range, $small, $whiteBrush, (S 70), (S ($Y + 8)))
  if ($Editable) {
    Draw-StepperButton $Graphics 238 ($Y + 3) $false
    $Graphics.DrawRectangle($pen, (S 260), (S ($Y + 3)), (S 28), (S 18))
    Draw-CenteredText $Graphics $Value $small $whiteBrush 274 ($Y + 12)
    Draw-StepperButton $Graphics 292 ($Y + 3) $true
  } else {
    $Graphics.DrawRectangle($pen, (S 252), (S ($Y + 3)), (S 52), (S 18))
    Draw-CenteredText $Graphics "AUTO" $small $whiteBrush 278 ($Y + 12)
  }
  $pen.Dispose(); $accentBrush.Dispose(); $whiteBrush.Dispose(); $font.Dispose(); $small.Dispose()
}

function Draw-Heart($Graphics, [int]$X, [int]$Y) {
  $red = [System.Drawing.SolidBrush]::new((New-Color 255 18 12))
  $Graphics.FillEllipse($red, (S ($X + 1)), (S $Y), (S 5), (S 5))
  $Graphics.FillEllipse($red, (S ($X + 5)), (S $Y), (S 5), (S 5))
  $points = [System.Drawing.Point[]]@(
    [System.Drawing.Point]::new((S ($X + 1)), (S ($Y + 5))),
    [System.Drawing.Point]::new((S ($X + 10)), (S ($Y + 5))),
    [System.Drawing.Point]::new((S ($X + 5)), (S ($Y + 11)))
  )
  $Graphics.FillPolygon($red, $points)
  $Graphics.FillRectangle($red, (S ($X + 2)), (S ($Y + 4)), (S 7), (S 2))
  $red.Dispose()
}

function Draw-CenteredText($Graphics, [string]$Text, $Font, [System.Drawing.Brush]$Brush, [double]$CenterX, [double]$Y) {
  $size = $Graphics.MeasureString($Text, $Font)
  $Graphics.DrawString($Text, $Font, $Brush, (S $CenterX) - ($size.Width / 2), (S $Y))
}

function Draw-TextFit($Graphics, [string]$Text, [double]$X, [double]$Y, [double]$MaxW, [System.Drawing.Font]$Large, [System.Drawing.Font]$Small, [System.Drawing.Brush]$Brush) {
  $font = $Large
  if ($Graphics.MeasureString($Text, $font).Width -gt (S $MaxW)) { $font = $Small }
  $Graphics.DrawString($Text, $font, $Brush, (S $X), (S $Y))
}

function Draw-MetricValue($Graphics, [double]$Money, [double]$Tokens, [double]$X, [double]$Y, [double]$MaxW, [System.Drawing.Brush]$Brush) {
  $moneyText = Format-Money $Money
  $tokenText = Format-ShortNumber $Tokens
  $fullText = "$moneyText/$tokenText"
  $moneyFont = New-Font "Segoe UI" 23 ([System.Drawing.FontStyle]::Bold)
  $tokenFont = New-Font "Segoe UI" 12 ([System.Drawing.FontStyle]::Bold)
  $fallbackFont = New-Font "Segoe UI" 13 ([System.Drawing.FontStyle]::Bold)
  $moneyW = $Graphics.MeasureString($moneyText, $moneyFont).Width
  $slashW = $Graphics.MeasureString("/", $tokenFont).Width
  $tokenW = $Graphics.MeasureString($tokenText, $tokenFont).Width
  if (($moneyW + $slashW + $tokenW) -gt (S $MaxW)) {
    Draw-TextFit $Graphics $fullText $X ($Y + 7) $MaxW $fallbackFont (New-Font "Segoe UI" 10 ([System.Drawing.FontStyle]::Bold)) $Brush
  } else {
    $Graphics.DrawString($moneyText, $moneyFont, $Brush, (S $X), (S $Y))
    $Graphics.DrawString("/", $tokenFont, $Brush, (S $X) + $moneyW, (S ($Y + 14)))
    $Graphics.DrawString($tokenText, $tokenFont, $Brush, (S $X) + $moneyW + $slashW, (S ($Y + 14)))
  }
  $moneyFont.Dispose(); $tokenFont.Dispose(); $fallbackFont.Dispose()
}

function Draw-Header($Graphics, [string]$ActiveMode) {
  $red = [System.Drawing.SolidBrush]::new((New-Color 255 18 12))
  $darkRed = [System.Drawing.SolidBrush]::new((New-Color 190 0 0))
  $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $whitePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, (S 1))
  $font = New-Font "Segoe UI" 13 ([System.Drawing.FontStyle]::Bold)
  $small = New-Font "Segoe UI" 12
  $tab = New-Font "Segoe UI" 10 ([System.Drawing.FontStyle]::Bold)

  $Graphics.FillRectangle($red, 0, 0, (S 320), (S 45))
  Fill-RoundRect $Graphics $white (S 14) (S 9) (S 44) (S 26) (S 13)
  Fill-RoundRect $Graphics $red (S 19) (S 14) (S 34) (S 16) (S 8)
  $Graphics.DrawString("Codex", $font, $white, (S 66), (S 5))
  $Graphics.DrawString("Headroom", $small, $white, (S 66), (S 21))

  $tabs = @(
    @{ x = 150; label = "DAY" },
    @{ x = 207; label = "WEEK" },
    @{ x = 264; label = "MONTH" }
  )
  foreach ($item in $tabs) {
    $active = $item.label -eq $ActiveMode
    Fill-RoundRect $Graphics $darkRed (S $item.x) (S 8) (S 52) (S 28) (S 5)
    if ($active) { Draw-RoundRect $Graphics $whitePen (S $item.x) (S 8) (S 52) (S 28) (S 5) }
    Draw-CenteredText $Graphics $item.label $tab $white ($item.x + 26) 16
  }

  $iconActive = $ActiveMode -eq "RANGE"
  Fill-RoundRect $Graphics $darkRed (S 294) (S 8) (S 18) (S 28) (S 5)
  if ($iconActive) { Draw-RoundRect $Graphics $whitePen (S 294) (S 8) (S 18) (S 28) (S 5) }
  $Graphics.DrawLine($whitePen, (S 298), (S 12), (S 298), (S 26))
  $Graphics.FillEllipse($white, (S 296), (S 14), (S 4), (S 4))
  $Graphics.DrawLine($whitePen, (S 303), (S 12), (S 303), (S 26))
  $Graphics.FillEllipse($white, (S 301), (S 20), (S 4), (S 4))
  $Graphics.DrawLine($whitePen, (S 308), (S 12), (S 308), (S 26))
  $Graphics.FillEllipse($white, (S 306), (S 16), (S 4), (S 4))

  $font.Dispose(); $small.Dispose(); $tab.Dispose(); $whitePen.Dispose()
  $red.Dispose(); $darkRed.Dispose(); $white.Dispose()
}

function Draw-Card($Graphics, [double]$X, [double]$Y, [double]$W, [double]$H, [string]$Label, [double]$Money, [double]$Tokens, [System.Drawing.Color]$Accent) {
  $pen = [System.Drawing.Pen]::new($Accent, (S 1))
  $accentBrush = [System.Drawing.SolidBrush]::new($Accent)
  $muted = [System.Drawing.SolidBrush]::new((New-Color 145 145 145))
  $labelFont = New-Font "Segoe UI" 12
  $Graphics.DrawRectangle($pen, (S $X), (S $Y), (S $W), (S $H))
  $Graphics.DrawString($Label, $labelFont, $muted, (S ($X + 5)), (S ($Y + 4)))
  Draw-MetricValue $Graphics $Money $Tokens ($X + 5) ($Y + 16) ($W - 10) $accentBrush
  $pen.Dispose(); $accentBrush.Dispose(); $muted.Dispose(); $labelFont.Dispose()
}

function Draw-Chart($Graphics, $Frame, [string]$Mode) {
  $x0 = 40; $y0 = 108; $w = 272; $h = 92
  $points = @(Get-ChartPoints $Frame $Mode)
  if ($points.Count -eq 0) { return }

  $cyanFill = [System.Drawing.SolidBrush]::new((New-Color 0 255 255))
  $greenFill = [System.Drawing.SolidBrush]::new((New-Color 0 255 0))
  $linePen = [System.Drawing.Pen]::new((New-Color 0 255 255), (S 1.5))
  $greenPen = [System.Drawing.Pen]::new((New-Color 0 255 0), (S 1.25))
  $gridPen = [System.Drawing.Pen]::new((New-Color 28 28 28), (S 1))
  $axisPen = [System.Drawing.Pen]::new((New-Color 92 92 92), (S 1))
  $textBrush = [System.Drawing.SolidBrush]::new((New-Color 145 145 145))
  $axisBrush = [System.Drawing.SolidBrush]::new((New-Color 92 92 92))
  $labelFont = New-Font "Segoe UI" 7
  $titleFont = New-Font "Segoe UI" 8

  $maxCost = 0.0
  $maxSavings = 0.0
  foreach ($point in $points) {
    $pointCost = [double]$point.cost
    $pointSavings = if ($null -ne $point.PSObject.Properties['usd']) { [double]$point.usd } else { 0.0 }
    if ($pointCost -gt $maxCost) { $maxCost = $pointCost }
    if ($pointSavings -gt $maxSavings) { $maxSavings = $pointSavings }
  }
  $maxValue = [Math]::Max(1.0, [Math]::Max($maxCost, $maxSavings))
  $topValue = Get-ChartTop $maxValue
  $step = Get-ChartStep $maxValue
  $baseY = $y0 + $h

  $coords = @()
  for ($i = 0; $i -lt $points.Count; $i++) {
    $x = if ($points.Count -eq 1) { $x0 + ($w / 2.0) } else { $x0 + (($w * $i) / ($points.Count - 1.0)) }
    $costValue = [Math]::Max(0.0, [double]$points[$i].cost)
    $rawSavingsValue = if ($null -ne $points[$i].PSObject.Properties['usd']) { [double]$points[$i].usd } else { 0.0 }
    $savingsValue = [Math]::Max(0.0, $rawSavingsValue)
    if ($savingsValue -gt $costValue) { $savingsValue = $costValue }
    $normalized = [Math]::Min(1.0, [Math]::Max(0.0, ($costValue / $topValue)))
    $savingsNormalized = [Math]::Min(1.0, [Math]::Max(0.0, ($savingsValue / $topValue)))
    $y = $baseY - ($normalized * $h)
    $savingsY = $baseY - ($savingsNormalized * $h)
    $coords += [pscustomobject]@{
      x = $x
      y = $y
      savingsY = [Math]::Min($baseY, $savingsY)
      t = [string]$points[$i].t
    }
  }

  if ($coords.Count -eq 1) {
    $singleX = [int][Math]::Round($coords[0].x)
    $singleY = [int][Math]::Round($coords[0].y)
    $singleSavingsY = [int][Math]::Round($coords[0].savingsY)
    $Graphics.FillRectangle($greenFill, (S ($singleX - 3)), (S $singleSavingsY), (S 6), (S ($baseY - $singleSavingsY)))
    $Graphics.FillRectangle($cyanFill, (S ($singleX - 3)), (S $singleY), (S 6), (S ($singleSavingsY - $singleY)))
    $Graphics.DrawLine($greenPen, (S ($singleX - 3)), (S $singleSavingsY), (S ($singleX + 3)), (S $singleSavingsY))
  } else {
    $areaPts = [System.Collections.Generic.List[System.Drawing.Point]]::new()
    $areaPts.Add([System.Drawing.Point]::new((S $coords[0].x), (S $baseY)))
    foreach ($coord in $coords) {
      $areaPts.Add([System.Drawing.Point]::new((S $coord.x), (S $coord.savingsY)))
    }
    $areaPts.Add([System.Drawing.Point]::new((S $coords[-1].x), (S $baseY)))
    $Graphics.FillPolygon($greenFill, $areaPts.ToArray())

    $capPts = [System.Collections.Generic.List[System.Drawing.Point]]::new()
    foreach ($coord in $coords) {
      $capPts.Add([System.Drawing.Point]::new((S $coord.x), (S $coord.y)))
    }
    for ($i = $coords.Count - 1; $i -ge 0; $i--) {
      $capPts.Add([System.Drawing.Point]::new((S $coords[$i].x), (S $coords[$i].savingsY)))
    }
    $Graphics.FillPolygon($cyanFill, $capPts.ToArray())

    for ($i = 1; $i -lt $coords.Count; $i++) {
      $Graphics.DrawLine($linePen, (S $coords[$i - 1].x), (S $coords[$i - 1].y), (S $coords[$i].x), (S $coords[$i].y))
      $Graphics.DrawLine($greenPen, (S $coords[$i - 1].x), (S $coords[$i - 1].savingsY), (S $coords[$i].x), (S $coords[$i].savingsY))
    }
  }

  $titleText = Get-ChartTitle $Mode
  $titleSize = $Graphics.MeasureString($titleText, $labelFont)
  $Graphics.DrawString($titleText, $labelFont, $textBrush, (S ($x0 + $w)) - $titleSize.Width, (S ($y0 - 12)))

  for ($tick = 0.0; $tick -le ($topValue + 0.1); $tick += $step) {
    $tickY = $baseY - (($tick / $topValue) * $h)
    $pen = if ($tick -eq 0.0) { $axisPen } else { $gridPen }
    $Graphics.DrawLine($pen, (S $x0), (S $tickY), (S ($x0 + $w)), (S $tickY))
    $label = [string]::Format($culture, '${0:0}', $tick)
    $size = $Graphics.MeasureString($label, $labelFont)
    $Graphics.DrawString($label, $labelFont, $axisBrush, (S ($x0 - 6)) - $size.Width, (S ($tickY - 5)))
  }

  $Graphics.DrawLine($axisPen, (S $x0), (S $y0), (S $x0), (S ($y0 + $h)))
  $Graphics.DrawLine($axisPen, (S $x0), (S ($y0 + $h)), (S ($x0 + $w)), (S ($y0 + $h)))

  $anchorIndexes = @(0, [int][Math]::Floor(($coords.Count - 1) / 2), ($coords.Count - 1))
  for ($anchor = 0; $anchor -lt $anchorIndexes.Count; $anchor++) {
    $idx = $anchorIndexes[$anchor]
    $label = Format-ChartXLabel ([string]$coords[$idx].t) $Mode
    $labelY = $y0 + $h + 6
    if ($anchor -eq 0) {
      $Graphics.DrawString($label, $labelFont, $axisBrush, (S ($coords[$idx].x + 12)), (S $labelY))
    } elseif ($anchor -eq 2) {
      $labelSize = $Graphics.MeasureString($label, $labelFont)
      $Graphics.DrawString($label, $labelFont, $axisBrush, (S ($coords[$idx].x - 2)) - $labelSize.Width, (S $labelY))
    } else {
      Draw-CenteredText $Graphics $label $labelFont $axisBrush $coords[$idx].x $labelY
    }
  }

  $cyanFill.Dispose(); $greenFill.Dispose(); $linePen.Dispose(); $greenPen.Dispose()
  $gridPen.Dispose(); $axisPen.Dispose(); $textBrush.Dispose(); $axisBrush.Dispose()
  $labelFont.Dispose(); $titleFont.Dispose()
}

function Draw-Settings($Graphics, $Agg, [bool]$ShowTimeZoneMenu = $false) {
  $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $muted = [System.Drawing.SolidBrush]::new((New-Color 145 145 145))
  $green = [System.Drawing.Color]::FromArgb(0,255,0)
  $orange = [System.Drawing.Color]::FromArgb(255,165,0)
  $red = [System.Drawing.Color]::FromArgb(255,0,0)
  $small = New-Font "Segoe UI" 8

  Draw-TimeZoneCombo $Graphics 64 $TimeZoneLabel
  if ($ShowTimeZoneMenu) {
    Draw-TimeZoneMenuOverlay $Graphics $TimeZoneLabel
    $white.Dispose(); $muted.Dispose(); $small.Dispose()
    return
  }
  $Graphics.DrawString("Alert ranges", $small, $muted, (S 8), (S 98))
  Draw-ThresholdRow $Graphics 108 "Low" "0-50" $green "50" $true
  Draw-ThresholdRow $Graphics 136 "Medium" "50-100" $orange "100" $true
  Draw-ThresholdRow $Graphics 164 "High" "100-MAX" $red "" $false

  $whitePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, (S 1))
  $Graphics.DrawRectangle($whitePen, (S 8), (S 206), (S 304), (S 16))
  Draw-CenteredText $Graphics "CALIBRATE TOUCH" $small $white 160 214

  $whitePen.Dispose()
  $white.Dispose(); $muted.Dispose(); $small.Dispose()
}

function Draw-WaitingScreen($Graphics) {
  $fontBig = New-Font "Segoe UI" 18 ([System.Drawing.FontStyle]::Bold)
  $fontSmall = New-Font "Segoe UI" 11
  $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)

  $columns = 18
  for ($i = 0; $i -lt $columns; $i++) {
    $x = 12 + ($i * 17) + (($i * 3) % 6)
    $head = 138 + (($i * 19) % 86)
    $length = 6 + ($i % 7)
    for ($j = 0; $j -lt $length; $j++) {
      $y = $head - ($j * 11)
      if ($y -lt 138 -or $y -gt 236) { continue }
      $digit = if ((($i + $j) % 2) -eq 0) { "0" } else { "1" }
      $color = if ($j -eq 0) { New-Color 255 120 120 } else { New-Color ([Math]::Max(45, 180 - ($j * 22))) 24 24 }
      $brush = [System.Drawing.SolidBrush]::new($color)
      $font = if ($j -eq 0) { $fontSmall } else { $fontSmall }
      $Graphics.DrawString($digit, $font, $brush, (S $x), (S $y))
      $brush.Dispose()
    }
  }

  Draw-CenteredText $Graphics "Waiting" $fontBig $white 160 96
  $fontBig.Dispose(); $fontSmall.Dispose(); $white.Dispose()
}

function Draw-Footer($Graphics, $Frame) {
  $bg = [System.Drawing.SolidBrush]::new((New-Color 5 5 5))
  $black = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Black)
  $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $red = [System.Drawing.SolidBrush]::new((New-Color 255 0 0))
  $yellow = [System.Drawing.SolidBrush]::new((New-Color 255 220 0))
  $font = New-Font "Segoe UI" 9
  $fontBold = New-Font "Segoe UI" 9 ([System.Drawing.FontStyle]::Bold)
  $y = 222
  $Graphics.FillRectangle($bg, 0, (S $y), (S 320), (S 18))
  $Graphics.FillRectangle($black, (S 240), (S $y), (S 80), (S 18))
  $Graphics.DrawString("Made with", $font, $white, (S 6), (S ($y + 4)))
  $Graphics.DrawString("love", $fontBold, $red, (S 58), (S ($y + 4)))
  $Graphics.DrawString("by", $font, $white, (S 86), (S ($y + 4)))
  $Graphics.DrawString("Joel Ganggini", $fontBold, $red, (S 100), (S ($y + 4)))
  $pct = 0.0
  if ($null -ne $Frame.session -and $null -ne $Frame.session.pct) { $pct = [double]$Frame.session.pct }
  $avg = [string]::Format($culture, "AVG {0:0.0}%", $pct)
  $avgSize = $Graphics.MeasureString($avg, $fontBold)
  $Graphics.DrawString($avg, $fontBold, $yellow, (S 280) - ($avgSize.Width / 2), (S ($y + 4)))
  $bg.Dispose(); $black.Dispose(); $white.Dispose(); $red.Dispose(); $yellow.Dispose(); $font.Dispose(); $fontBold.Dispose()
}

$frame = Get-PreviewFrame
$periodMode = if ($Mode -eq "RANGE" -or $Mode -eq "WAITING") { "DAY" } else { $Mode }
$agg = Get-Aggregate $frame $periodMode
$bitmap = [System.Drawing.Bitmap]::new((S 320), (S 240), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$black = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Black)
$graphics.FillRectangle($black, 0, 0, $bitmap.Width, $bitmap.Height)

Draw-Header $graphics $Mode
if ($Mode -eq "WAITING") {
  Draw-WaitingScreen $graphics
} elseif ($Mode -eq "RANGE") {
  Draw-Settings $graphics $agg $false
} elseif ($Mode -eq "RANGE_MENU") {
  Draw-Settings $graphics $agg $true
} else {
  Draw-Card $graphics 12 54 142 32 "Consumed" $agg.cost $agg.input (New-Color 0 255 255)
  if ($agg.cost -ge 100) {
    Draw-AlertIndicator $graphics 146 64 (New-Color 255 0 0)
  } elseif ($agg.cost -ge 50) {
    Draw-AlertIndicator $graphics 146 64 (New-Color 255 165 0)
  } else {
    Draw-AlertIndicator $graphics 146 64 (New-Color 0 255 0)
  }
  Draw-Card $graphics 166 54 142 32 "Savings" $agg.usd $agg.saved (New-Color 0 255 0)
  Draw-Chart $graphics $frame $Mode
  Draw-Footer $graphics $frame
}

$resolved = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath
} else {
  Join-Path (Get-Location) $OutputPath
}
$dir = Split-Path -Parent $resolved
if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bitmap.Save($resolved, [System.Drawing.Imaging.ImageFormat]::Png)

$graphics.Dispose()
$bitmap.Dispose()
$black.Dispose()

Write-Host $resolved
