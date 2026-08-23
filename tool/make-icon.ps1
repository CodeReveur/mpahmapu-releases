# The app's own mark as a launcher icon on both platforms: the orange rounded
# square with the black two-wheeler glyph, drawn from the same Material font
# Flutter ships, so the icon on the home screen and the badge inside the app
# are the same drawing.
param(
  [Parameter(Mandatory = $true)][string]$FontPath,
  [Parameter(Mandatory = $true)][string]$Root
)

Add-Type -AssemblyName System.Drawing

$orange = [System.Drawing.Color]::FromArgb(255, 249, 115, 22)  # Brand.orange
$black  = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
$glyph  = [char]0xE689                                          # Icons.two_wheeler

$fonts = New-Object System.Drawing.Text.PrivateFontCollection
$fonts.AddFontFile($FontPath)
$family = $fonts.Families[0]

function New-Icon {
  param(
    [int]$Size,
    [string]$Shape = 'rounded',   # rounded | square | none
    [double]$GlyphScale = 0.56
  )

  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $g.Clear([System.Drawing.Color]::Transparent)

  if ($Shape -eq 'rounded') {
    $brush = New-Object System.Drawing.SolidBrush($orange)
    $r = [int]($Size * 0.297)   # the same corner the app draws on its badge
    $d = $r * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($Size - $d, 0, $d, $d, 270, 90)
    $path.AddArc($Size - $d, $Size - $d, $d, $d, 0, 90)
    $path.AddArc(0, $Size - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath($brush, $path)
    $path.Dispose(); $brush.Dispose()
  } elseif ($Shape -eq 'square') {
    # iOS masks the corners itself and refuses any transparency.
    $brush = New-Object System.Drawing.SolidBrush($orange)
    $g.FillRectangle($brush, 0, 0, $Size, $Size)
    $brush.Dispose()
  }

  # The font's line box carries descender space the glyph does not use, which
  # leaves it sitting high. Nudge it back to where the eye expects it.
  $fontSize = [float]($Size * $GlyphScale)
  $font = New-Object System.Drawing.Font($family, $fontSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.Alignment = [System.Drawing.StringAlignment]::Center
  $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
  $rect = New-Object System.Drawing.RectangleF(0, [float]($Size * 0.035), $Size, $Size)
  $ink = New-Object System.Drawing.SolidBrush($black)
  $g.DrawString([string]$glyph, $font, $ink, $rect, $fmt)

  $ink.Dispose(); $font.Dispose(); $fmt.Dispose(); $g.Dispose()
  return $bmp
}

function Save-Icon {
  param([System.Drawing.Bitmap]$Bitmap, [string]$Path)
  $dir = Split-Path $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $Bitmap.Dispose()
}

# ── Android ───────────────────────────────────────────────────────────────
$res = Join-Path $Root 'android\app\src\main\res'
$densities = @{
  'mipmap-mdpi' = 48; 'mipmap-hdpi' = 72; 'mipmap-xhdpi' = 96
  'mipmap-xxhdpi' = 144; 'mipmap-xxxhdpi' = 192
}
foreach ($entry in $densities.GetEnumerator()) {
  $dir = Join-Path $res $entry.Key
  $size = [int]$entry.Value
  Save-Icon (New-Icon -Size $size -Shape 'rounded' -GlyphScale 0.56) (Join-Path $dir 'ic_launcher.png')
  # The adaptive foreground is masked to whatever shape the launcher wants, so
  # its glyph sits well inside the safe zone with the orange behind it.
  Save-Icon (New-Icon -Size ($size * 2) -Shape 'none' -GlyphScale 0.34) (Join-Path $dir 'ic_launcher_foreground.png')
}

# ── iOS ───────────────────────────────────────────────────────────────────
$appicon = Join-Path $Root 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
$ios = @{
  'Icon-App-20x20@1x.png' = 20;    'Icon-App-20x20@2x.png' = 40;   'Icon-App-20x20@3x.png' = 60
  'Icon-App-29x29@1x.png' = 29;    'Icon-App-29x29@2x.png' = 58;   'Icon-App-29x29@3x.png' = 87
  'Icon-App-40x40@1x.png' = 40;    'Icon-App-40x40@2x.png' = 80;   'Icon-App-40x40@3x.png' = 120
  'Icon-App-60x60@2x.png' = 120;   'Icon-App-60x60@3x.png' = 180
  'Icon-App-76x76@1x.png' = 76;    'Icon-App-76x76@2x.png' = 152
  'Icon-App-83.5x83.5@2x.png' = 167
  'Icon-App-1024x1024@1x.png' = 1024
}
foreach ($entry in $ios.GetEnumerator()) {
  Save-Icon (New-Icon -Size ([int]$entry.Value) -Shape 'square' -GlyphScale 0.60) (Join-Path $appicon $entry.Key)
}

# The 512px icon a Play listing asks for, kept out of res/ where Android would
# refuse it as a stray resource.
Save-Icon (New-Icon -Size 512 -Shape 'rounded' -GlyphScale 0.56) (Join-Path $Root 'play-store-icon.png')

Write-Output "icons written for android and ios"
