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

Add-Type -AssemblyName System.Drawing

function S([double]$Value) { [int][Math]::Round($Value * $script:Scale) }

function New-Color([int]$R, [int]$G, [int]$B, [int]$A = 255) {
  [System.Drawing.Color]::FromArgb($A, $R, $G, $B)
}

function New-Font([string]$Name, [double]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular) {
  [System.Drawing.Font]::new($Name, [single](S $Size), $Style, [System.Drawing.GraphicsUnit]::Pixel)
}

function New-RoundRectPath([double]$X, [double]$Y, [double]$Width, [double]$Height, [double]$Radius) {
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  if ($Radius -le 0) {
    $path.AddRectangle([System.Drawing.RectangleF]::new([single](S $X), [single](S $Y), [single](S $Width), [single](S $Height)))
    return $path
  }

  $r = S $Radius
  $d = $r * 2
  $sx = S $X
  $sy = S $Y
  $sw = S $Width
  $sh = S $Height

  $path.AddArc($sx, $sy, $d, $d, 180, 90)
  $path.AddArc($sx + $sw - $d, $sy, $d, $d, 270, 90)
  $path.AddArc($sx + $sw - $d, $sy + $sh - $d, $d, $d, 0, 90)
  $path.AddArc($sx, $sy + $sh - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

function Fill-RoundRect($Graphics, $Color, [double]$X, [double]$Y, [double]$Width, [double]$Height, [double]$Radius) {
  $brush = [System.Drawing.SolidBrush]::new($Color)
  $path = New-RoundRectPath $X $Y $Width $Height $Radius
  $Graphics.FillPath($brush, $path)
  $path.Dispose()
  $brush.Dispose()
}

function Draw-RoundRect($Graphics, $Color, [double]$X, [double]$Y, [double]$Width, [double]$Height, [double]$Radius, [double]$Thickness = 1) {
  $pen = [System.Drawing.Pen]::new($Color, [single](S $Thickness))
  $path = New-RoundRectPath $X $Y $Width $Height $Radius
  $Graphics.DrawPath($pen, $path)
  $path.Dispose()
  $pen.Dispose()
}

function Draw-Text($Graphics, [string]$Text, $Font, $Color, [double]$X, [double]$Y, [string]$Align = "Left") {
  $brush = [System.Drawing.SolidBrush]::new($Color)
  $format = [System.Drawing.StringFormat]::new()
  $rectX = $X
  switch ($Align) {
    "Center" {
      $format.Alignment = [System.Drawing.StringAlignment]::Center
      $rectX = $X - 100
    }
    "Right" {
      $format.Alignment = [System.Drawing.StringAlignment]::Far
      $rectX = $X - 200
    }
    default {
      $format.Alignment = [System.Drawing.StringAlignment]::Near
      $rectX = $X
    }
  }
  $format.LineAlignment = [System.Drawing.StringAlignment]::Near
  $rect = [System.Drawing.RectangleF]::new([single](S $rectX), [single](S $Y), [single](S 200), [single](S 40))
  $Graphics.DrawString($Text, $Font, $brush, $rect, $format)
  $format.Dispose()
  $brush.Dispose()
}

function Format-Currency([double]$Value) {
  return ('$' + [Math]::Round($Value, 2).ToString('0.00', $culture))
}

function Format-Tokens([double]$Value) {
  if ($Value -ge 1000000) { return ('{0:0.0}M' -f ($Value / 1000000.0)) }
  if ($Value -ge 1000) { return ('{0:0.0}k' -f ($Value / 1000.0)) }
  return [Math]::Round($Value).ToString($culture)
}

function Get-TimeZoneOffsetMinutes([string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Label)) { return -300 }
  $match = [regex]::Match($Label, '^UTC([+-])(\d{2}):(\d{2})$')
  if (-not $match.Success) { return -300 }
  $sign = if ($match.Groups[1].Value -eq '-') { -1 } else { 1 }
  return $sign * (([int]$match.Groups[2].Value * 60) + [int]$match.Groups[3].Value)
}

function New-SeriesPoint([string]$Label, [double]$ConsumedUsd, [double]$SavedUsd, [double]$InputTokens, [double]$SavedTokens) {
  [pscustomobject][ordered]@{
    label = $Label
    consumed_usd = [Math]::Round($ConsumedUsd, 6)
    saved_usd = [Math]::Round($SavedUsd, 6)
    input_tokens = [uint32][Math]::Round([Math]::Max(0.0, $InputTokens))
    saved_tokens = [uint32][Math]::Round([Math]::Max(0.0, $SavedTokens))
  }
}

function New-View([string]$Title, [array]$Series) {
  $consumed = 0.0
  $savedUsd = 0.0
  $inputTokens = 0.0
  $savedTokens = 0.0
  foreach ($point in $Series) {
    $consumed += [double]$point.consumed_usd
    $savedUsd += [double]$point.saved_usd
    $inputTokens += [double]$point.input_tokens
    $savedTokens += [double]$point.saved_tokens
  }
  $avgPct = if ($consumed -gt 0.0) { ($savedUsd / $consumed) * 100.0 } else { 0.0 }
  [pscustomobject][ordered]@{
    title = $Title
    consumed_usd = [Math]::Round($consumed, 6)
    saved_usd = [Math]::Round($savedUsd, 6)
    input_tokens = [uint32][Math]::Round($inputTokens)
    saved_tokens = [uint32][Math]::Round($savedTokens)
    avg_pct = [Math]::Round($avgPct, 1)
    series = @($Series)
  }
}

function Get-WeekStart([datetime]$Date) {
  $daysSinceMonday = (([int]$Date.DayOfWeek + 6) % 7)
  return $Date.AddDays(-$daysSinceMonday).Date
}

function Get-NextMonthBucketStart([datetime]$BucketStart, [datetime]$MonthStart) {
  if ($BucketStart -eq $MonthStart) {
    $next = (Get-WeekStart $BucketStart).AddDays(7)
    if ($next -le $BucketStart) { $next = $BucketStart.AddDays(7) }
    return $next.Date
  }
  return $BucketStart.AddDays(7).Date
}

function New-FixtureFrame {
  $now = Get-Date
  $daySeries = @()
  for ($hour = 0; $hour -le $now.Hour; ++$hour) {
    $consumed = 0.8 + ([Math]::Abs([Math]::Sin(($hour + 1) / 2.4)) * 8.4)
    if ($hour -ge 9 -and $hour -le 15) { $consumed += 5.5 }
    $saved = $consumed * (0.035 + (($hour % 5) * 0.008))
    $input = 850000 + ($hour * 125000)
    $tokensSaved = $saved * 32000.0
    $daySeries += New-SeriesPoint ("{0:00}h" -f $hour) $consumed $saved $input $tokensSaved
  }

  $weekSeries = @()
  $weekStart = Get-WeekStart $now.Date
  $dayCount = ($now.Date - $weekStart).Days
  for ($i = 0; $i -le $dayCount; ++$i) {
    $date = $weekStart.AddDays($i)
    $consumed = 9.0 + ($i * 2.8)
    $saved = $consumed * (0.04 + ($i * 0.006))
    $weekSeries += New-SeriesPoint ($date.ToString('dd/MM', $culture)) $consumed $saved (4200000 + ($i * 380000)) ($saved * 41000.0)
  }

  $monthSeries = @()
  $monthStart = [datetime]::new($now.Year, $now.Month, 1)
  $rangeEndExclusive = $now.Date.AddDays(1)
  $cursor = $monthStart
  $weekIndex = 0
  while ($cursor -lt $rangeEndExclusive) {
    $next = Get-NextMonthBucketStart $cursor $monthStart
    if ($next -gt $rangeEndExclusive) { $next = $rangeEndExclusive }
    $consumed = 24.0 + ($weekIndex * 12.5)
    $saved = $consumed * (0.028 + ($weekIndex * 0.01))
    $monthSeries += New-SeriesPoint ($cursor.ToString('dd/MM', $culture)) $consumed $saved (11000000 + ($weekIndex * 900000)) ($saved * 52000.0)
    $cursor = $next
    $weekIndex++
  }

  [pscustomobject][ordered]@{
    v = 3
    ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    ok = $true
    tz_offset_minutes = Get-TimeZoneOffsetMinutes $TimeZoneLabel
    session = [pscustomobject][ordered]@{
      req = 1506
      saved = 1087030
      usd = 3.46
      pct = 4.8
      input = 85332509
      last = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    live = [pscustomobject][ordered]@{
      rtkCmd = 704
      rtkSaved = 1087030
      rtkPct = 6.12
      proxy = 'healthy'
      uptime = 4693
    }
    views = [pscustomobject][ordered]@{
      day = New-View 'USD by hour' $daySeries
      week = New-View 'USD by day' $weekSeries
      month = New-View 'USD by week' $monthSeries
    }
  }
}

function Get-PreviewFrame {
  if (-not $LiveData) {
    return New-FixtureFrame
  }

  $bridgePath = Join-Path $PSScriptRoot 'headroom-live-bridge.ps1'
  $offset = Get-TimeZoneOffsetMinutes $TimeZoneLabel
  try {
    $line = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bridgePath -Once -DryRun -TimeZoneOffsetMinutes $offset 2>$null | Select-Object -Last 1
    if ($line -and $line.StartsWith('HRM2 ')) {
      return ($line.Substring(5) | ConvertFrom-Json)
    }
  } catch {
  }

  return New-FixtureFrame
}

function Get-ActiveView($Frame, [string]$CurrentMode) {
  switch ($CurrentMode) {
    'WEEK' { return $Frame.views.week }
    'MONTH' { return $Frame.views.month }
    default { return $Frame.views.day }
  }
}

function Get-AlertColor([double]$ConsumedUsd) {
  if ($ConsumedUsd -lt 50.0) { return (New-Color 0 255 0) }
  if ($ConsumedUsd -lt 100.0) { return (New-Color 255 165 0) }
  return (New-Color 255 0 0)
}

function Get-ChartTickStep([double]$MaxValue) {
  if ($MaxValue -le 5.0) { return 1.0 }
  if ($MaxValue -le 10.0) { return 2.0 }
  if ($MaxValue -le 25.0) { return 5.0 }
  if ($MaxValue -le 50.0) { return 10.0 }
  return 25.0
}

function Get-ChartTopValue([double]$MaxValue) {
  $step = Get-ChartTickStep $MaxValue
  return [Math]::Max($step, [Math]::Ceiling($MaxValue / $step) * $step)
}

function Draw-OracleMark($Graphics, [double]$X, [double]$Y) {
  $white = New-Color 255 255 255
  $brush = [System.Drawing.SolidBrush]::new($white)
  $innerBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Transparent)
  $outer = [System.Drawing.RectangleF]::new([single](S $X), [single](S $Y), [single](S 28), [single](S 14))
  $inner = [System.Drawing.RectangleF]::new([single](S ($X + 4)), [single](S ($Y + 4)), [single](S 20), [single](S 6))
  $Graphics.FillEllipse($brush, $outer)
  $Graphics.FillEllipse([System.Drawing.Brushes]::Black, $inner)
  $brush.Dispose()
  $innerBrush.Dispose()
}

function Draw-SettingsIcon($Graphics, [double]$X, [double]$Y) {
  $pen = [System.Drawing.Pen]::new((New-Color 255 255 255), [single](S 1.5))
  $Graphics.DrawLine($pen, (S ($X + 4)), (S ($Y + 8)), (S ($X + 20)), (S ($Y + 8)))
  $Graphics.DrawLine($pen, (S ($X + 4)), (S ($Y + 14)), (S ($X + 20)), (S ($Y + 14)))
  $Graphics.DrawLine($pen, (S ($X + 4)), (S ($Y + 20)), (S ($X + 20)), (S ($Y + 20)))
  $Graphics.FillEllipse([System.Drawing.Brushes]::White, (S ($X + 7)), (S ($Y + 5)), (S 6), (S 6))
  $Graphics.FillEllipse([System.Drawing.Brushes]::White, (S ($X + 13)), (S ($Y + 11)), (S 6), (S 6))
  $Graphics.FillEllipse([System.Drawing.Brushes]::White, (S ($X + 9)), (S ($Y + 17)), (S 6), (S 6))
  $pen.Dispose()
}

function Draw-Header($Graphics, [string]$CurrentMode) {
  Fill-RoundRect $Graphics (New-Color 20 20 34) 0 0 320 46 0
  $polyBrush = [System.Drawing.SolidBrush]::new((New-Color 229 233 255))
  $points = [System.Drawing.Point[]]@(
    [System.Drawing.Point]::new((S 0), (S 44)),
    [System.Drawing.Point]::new((S 80), (S 4)),
    [System.Drawing.Point]::new((S 192), (S 4)),
    [System.Drawing.Point]::new((S 120), (S 44))
  )
  $Graphics.FillPolygon($polyBrush, $points)
  $polyBrush.Dispose()

  Draw-OracleMark $Graphics 8 9
  $fontTitle = New-Font 'Segoe UI' 12 ([System.Drawing.FontStyle]::Bold)
  Draw-Text $Graphics 'Codex' $fontTitle (New-Color 255 255 255) 46 7
  Draw-Text $Graphics 'Headroom' $fontTitle (New-Color 255 255 255) 46 20
  $fontTitle.Dispose()

  $buttons = @(
    @{ label = 'DAY'; x = 194; selected = ($CurrentMode -eq 'DAY') },
    @{ label = 'WEEK'; x = 232; selected = ($CurrentMode -eq 'WEEK') },
    @{ label = 'MONTH'; x = 275; selected = ($CurrentMode -eq 'MONTH') }
  )

  foreach ($button in $buttons) {
    $bg = if ($button.selected) { New-Color 228 110 139 } else { New-Color 70 24 34 }
    Fill-RoundRect $Graphics $bg $button.x 7 34 16 3
    $border = if ($button.selected) { New-Color 255 255 255 } else { $bg }
    Draw-RoundRect $Graphics $border $button.x 7 34 16 3 1
    $font = New-Font 'Segoe UI' 6 ([System.Drawing.FontStyle]::Bold)
    Draw-Text $Graphics $button.label $font (New-Color 255 255 255) ($button.x + 17) 10 'Center'
    $font.Dispose()
  }

  Fill-RoundRect $Graphics (New-Color 40 40 40) 302 7 14 16 3
  Draw-SettingsIcon $Graphics 302 4
}

function Draw-Card($Graphics, [double]$X, [string]$Title, [double]$Value, [double]$SecondaryValue, $Accent) {
  Fill-RoundRect $Graphics (New-Color 15 21 30) $X 54 148 32 3
  Draw-RoundRect $Graphics $Accent $X 54 148 32 3 1
  $titleFont = New-Font 'Segoe UI' 6 ([System.Drawing.FontStyle]::Bold)
  $valueFont = New-Font 'Segoe UI' 11 ([System.Drawing.FontStyle]::Bold)
  $detailFont = New-Font 'Segoe UI' 7
  Draw-Text $Graphics $Title $titleFont (New-Color 255 255 255) ($X + 8) 58
  Draw-Text $Graphics (Format-Currency $Value) $valueFont $Accent ($X + 8) 67
  Draw-Text $Graphics ('/' + (Format-Tokens $SecondaryValue)) $detailFont (New-Color 190 196 200) ($X + 56) 69
  $titleFont.Dispose()
  $valueFont.Dispose()
  $detailFont.Dispose()
}

function Draw-Chart($Graphics, $View) {
  $series = @($View.series)
  if ($series.Count -eq 0) { return }

  $x0 = 40.0
  $y0 = 108.0
  $w = 272.0
  $h = 92.0
  $gridColor = New-Color 28 28 28
  $axisColor = New-Color 92 92 92
  $lineColor = New-Color 0 255 255
  $fillCost = New-Color 0 255 255 90
  $fillSaved = New-Color 0 255 0 150

  $maxValue = 1.0
  foreach ($point in $series) {
    $maxValue = [Math]::Max($maxValue, [double]$point.consumed_usd)
    $maxValue = [Math]::Max($maxValue, [double]$point.saved_usd)
  }
  $topValue = Get-ChartTopValue $maxValue
  $tickStep = Get-ChartTickStep $maxValue

  $titleFont = New-Font 'Segoe UI' 7 ([System.Drawing.FontStyle]::Bold)
  Draw-Text $Graphics ([string]$View.title) $titleFont (New-Color 255 255 255) ($x0 + $w) 95 'Right'
  $titleFont.Dispose()

  $penGrid = [System.Drawing.Pen]::new($gridColor, [single](S 1))
  $penAxis = [System.Drawing.Pen]::new($axisColor, [single](S 1))
  $fontAxis = New-Font 'Segoe UI' 6

  for ($tick = 0.0; $tick -le ($topValue + 0.001); $tick += $tickStep) {
    $y = $y0 + $h - (($tick / $topValue) * $h)
    $Graphics.DrawLine($penGrid, (S $x0), (S $y), (S ($x0 + $w)), (S $y))
    Draw-Text $Graphics ('$' + [Math]::Round($tick).ToString('0', $culture)) $fontAxis (New-Color 170 170 170) 0 ($y - 4) 'Right'
  }

  $Graphics.DrawLine($penAxis, (S $x0), (S $y0), (S $x0), (S ($y0 + $h)))
  $Graphics.DrawLine($penAxis, (S $x0), (S ($y0 + $h)), (S ($x0 + $w)), (S ($y0 + $h)))

  $pointCount = [int]($series.Count)
  $costPoints = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
  $savedPoints = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
  $costPoints.Add([System.Drawing.PointF]::new([single](S $x0), [single](S ($y0 + $h))))
  $savedPoints.Add([System.Drawing.PointF]::new([single](S $x0), [single](S ($y0 + $h))))

  for ($i = 0; $i -lt $pointCount; ++$i) {
    $x = if ($pointCount -le 1) { $x0 + ($w / 2.0) } else { $x0 + (($w * $i) / ($pointCount - 1.0)) }
    $cost = [double]$series[$i].consumed_usd
    $saved = [Math]::Min($cost, [double]$series[$i].saved_usd)
    $costY = $y0 + $h - (($cost / $topValue) * $h)
    $savedY = $y0 + $h - (($saved / $topValue) * $h)
    $costPoints.Add([System.Drawing.PointF]::new([single](S $x), [single](S $costY)))
    $savedPoints.Add([System.Drawing.PointF]::new([single](S $x), [single](S $savedY)))
  }

  $lastX = if ($pointCount -le 1) { $x0 + ($w / 2.0) } else { $x0 + $w }
  $costPoints.Add([System.Drawing.PointF]::new([single](S $lastX), [single](S ($y0 + $h))))
  $savedPoints.Add([System.Drawing.PointF]::new([single](S $lastX), [single](S ($y0 + $h))))

  $brushCost = [System.Drawing.SolidBrush]::new($fillCost)
  $brushSaved = [System.Drawing.SolidBrush]::new($fillSaved)
  $Graphics.FillPolygon($brushCost, $costPoints.ToArray())
  $Graphics.FillPolygon($brushSaved, $savedPoints.ToArray())
  $brushCost.Dispose()
  $brushSaved.Dispose()

  $penCost = [System.Drawing.Pen]::new($lineColor, [single](S 1.4))
  $penSaved = [System.Drawing.Pen]::new((New-Color 0 255 0), [single](S 1.4))
  for ($i = 1; $i -lt $pointCount; ++$i) {
    $x1 = if ($pointCount -le 1) { $x0 + ($w / 2.0) } else { $x0 + (($w * ($i - 1)) / ($pointCount - 1.0)) }
    $x2 = if ($pointCount -le 1) { $x0 + ($w / 2.0) } else { $x0 + (($w * $i) / ($pointCount - 1.0)) }
    $cost1 = [double]$series[$i - 1].consumed_usd
    $cost2 = [double]$series[$i].consumed_usd
    $saved1 = [Math]::Min($cost1, [double]$series[$i - 1].saved_usd)
    $saved2 = [Math]::Min($cost2, [double]$series[$i].saved_usd)
    $y1 = $y0 + $h - (($cost1 / $topValue) * $h)
    $y2 = $y0 + $h - (($cost2 / $topValue) * $h)
    $sy1 = $y0 + $h - (($saved1 / $topValue) * $h)
    $sy2 = $y0 + $h - (($saved2 / $topValue) * $h)
    $Graphics.DrawLine($penCost, (S $x1), (S $y1), (S $x2), (S $y2))
    $Graphics.DrawLine($penSaved, (S $x1), (S $sy1), (S $x2), (S $sy2))
  }
  $penCost.Dispose()
  $penSaved.Dispose()

  $middleAnchor = [int][Math]::Floor((([int]$pointCount) - 1) / 2.0)
  $lastAnchor = ([int]$pointCount) - 1
  $anchors = [System.Collections.Generic.List[int]]::new()
  foreach ($anchorIndex in @(0, $middleAnchor, $lastAnchor)) {
    if (-not $anchors.Contains($anchorIndex)) {
      $anchors.Add($anchorIndex)
    }
  }
  for ($a = 0; $a -lt $anchors.Count; ++$a) {
    $idx = $anchors[$a]
    $x = if ($pointCount -le 1) { $x0 + ($w / 2.0) } else { $x0 + (($w * $idx) / ($pointCount - 1.0)) }
    $align = if ($a -eq 0) { 'Left' } elseif ($a -eq ($anchors.Count - 1)) { 'Right' } else { 'Center' }
    $labelX = if ($a -eq 0) { $x + 12 } elseif ($a -eq ($anchors.Count - 1)) { $x - 12 } else { $x }
    Draw-Text $Graphics ([string]$series[$idx].label) $fontAxis (New-Color 170 170 170) $labelX ($y0 + $h + 6) $align
  }

  $fontAxis.Dispose()
  $penGrid.Dispose()
  $penAxis.Dispose()
}

function Draw-Footer($Graphics, $View, $AlertColor) {
  Fill-RoundRect $Graphics (New-Color 5 5 5) 0 218 320 22 0
  Fill-RoundRect $Graphics (New-Color 0 0 0) 240 218 80 22 0
  $fontFooter = New-Font 'Segoe UI' 6
  $fontFooterBold = New-Font 'Segoe UI' 6 ([System.Drawing.FontStyle]::Bold)
  Draw-Text $Graphics 'Made with' $fontFooter (New-Color 255 255 255) 7 223
  Draw-Text $Graphics 'love' $fontFooterBold (New-Color 255 0 0) 50 223
  Draw-Text $Graphics 'by' $fontFooter (New-Color 255 255 255) 74 223
  Draw-Text $Graphics 'Joel Gangini' $fontFooterBold (New-Color 255 0 0) 92 223

  $brush = [System.Drawing.SolidBrush]::new($AlertColor)
  $Graphics.FillEllipse($brush, (S 243), (S 224), (S 8), (S 8))
  $brush.Dispose()

  Draw-Text $Graphics ('AVG ' + ([double]$View.avg_pct).ToString('0.0', $culture) + '%') $fontFooterBold (New-Color 255 220 0) 282 223 'Center'
  $fontFooter.Dispose()
  $fontFooterBold.Dispose()
}

function Draw-Waiting($Graphics) {
  Draw-Header $Graphics 'DAY'
  $font = New-Font 'Segoe UI' 11 ([System.Drawing.FontStyle]::Bold)
  Draw-Text $Graphics 'Waiting' $font (New-Color 255 255 255) 20 68
  $font.Dispose()

  $matrixFont = New-Font 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
  $brush = [System.Drawing.SolidBrush]::new((New-Color 200 20 20 170))
  for ($x = 0; $x -lt 13; ++$x) {
    for ($y = 0; $y -lt 8; ++$y) {
      $digit = (($x * 3 + $y * 7) % 10).ToString($culture)
      $Graphics.DrawString($digit, $matrixFont, $brush, [single](S (16 + ($x * 22))), [single](S (96 + ($y * 14))))
    }
  }
  $brush.Dispose()
  $matrixFont.Dispose()
}

function Draw-Settings($Graphics, $View, [bool]$MenuOpen) {
  Draw-Header $Graphics 'RANGE'
  Fill-RoundRect $Graphics (New-Color 10 14 20) 8 54 304 150 4
  Draw-RoundRect $Graphics (New-Color 45 45 45) 8 54 304 150 4 1
  $titleFont = New-Font 'Segoe UI' 8 ([System.Drawing.FontStyle]::Bold)
  $labelFont = New-Font 'Segoe UI' 7
  Draw-Text $Graphics 'Timezone' $titleFont (New-Color 255 255 255) 18 66
  Fill-RoundRect $Graphics (New-Color 22 28 36) 18 82 132 22 3
  Draw-RoundRect $Graphics (New-Color 92 92 92) 18 82 132 22 3 1
  Draw-Text $Graphics $TimeZoneLabel $labelFont (New-Color 255 255 255) 28 88

  Draw-Text $Graphics 'Low  0-50' $titleFont (New-Color 0 255 0) 18 118
  Draw-Text $Graphics 'Medium 50-100' $titleFont (New-Color 255 165 0) 18 142
  Draw-Text $Graphics 'High 100-MAX' $titleFont (New-Color 255 0 0) 18 166
  Draw-Text $Graphics ('Current AVG ' + ([double]$View.avg_pct).ToString('0.0', $culture) + '%') $labelFont (New-Color 255 220 0) 18 192

  if ($MenuOpen) {
    Fill-RoundRect $Graphics (New-Color 18 18 18) 158 82 122 58 3
    Draw-RoundRect $Graphics (New-Color 255 255 255) 158 82 122 58 3 1
    Draw-Text $Graphics 'UTC-05:00' $labelFont (New-Color 255 255 255) 168 90
    Draw-Text $Graphics 'UTC+00:00' $labelFont (New-Color 180 180 180) 168 106
    Draw-Text $Graphics 'UTC+01:00' $labelFont (New-Color 180 180 180) 168 122
  }

  $titleFont.Dispose()
  $labelFont.Dispose()
}

$frame = Get-PreviewFrame
$view = Get-ActiveView $frame $Mode
$alertColor = Get-AlertColor ([double]$view.consumed_usd)

$width = S 320
$height = S 240
$bitmap = [System.Drawing.Bitmap]::new($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$graphics.Clear([System.Drawing.Color]::Black)

switch ($Mode) {
  'WAITING' {
    Draw-Waiting $graphics
  }
  'RANGE_MENU' {
    Draw-Settings $graphics $view $true
  }
  'RANGE' {
    Draw-Settings $graphics $view $false
  }
  default {
    Draw-Header $graphics $Mode
    Draw-Card $graphics 8 'Consumed' ([double]$view.consumed_usd) ([double]$view.input_tokens) (New-Color 0 255 255)
    Draw-Card $graphics 164 'Savings' ([double]$view.saved_usd) ([double]$view.saved_tokens) (New-Color 0 255 0)
    Draw-Chart $graphics $view
    Draw-Footer $graphics $view $alertColor
  }
}

$directory = Split-Path -Parent $OutputPath
if ($directory -and -not (Test-Path $directory)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$baseDir = if ($directory) { (Resolve-Path -LiteralPath $directory).Path } else { (Get-Location).Path }
$finalPath = Join-Path $baseDir (Split-Path -Leaf $OutputPath)
$bitmap.Save($finalPath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
Write-Output $finalPath
