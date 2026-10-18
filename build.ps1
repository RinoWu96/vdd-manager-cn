<#
.SYNOPSIS
    构建 VDDManager.exe（启动器）和 VDDManager.ico（图标）。
    只用 Windows 自带的 .NET Framework 4（csc.exe、System.Drawing），不需要安装开发工具。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1             # 构建
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -Package    # 构建并打包发布用的 zip
#>
param([switch]$Package)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Add-Type -AssemblyName System.Drawing

# ---------- 图标：蓝色圆角底 + 白色显示器 ----------
function New-IconPng([int]$s) {   # 返回 Bitmap
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = 2 * $r
        $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
        $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
        $p.CloseFigure(); return $p
    }

    $bg = RoundRect 0 0 ($s - 1) ($s - 1) ($s * 0.22)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($s, $s)),
        [System.Drawing.Color]::FromArgb(59, 130, 246), [System.Drawing.Color]::FromArgb(29, 78, 216))
    $g.FillPath($grad, $bg)

    $white = [System.Drawing.Color]::White
    $stroke = [Math]::Max(1.5, $s * 0.07)
    $pen = New-Object System.Drawing.Pen($white, $stroke)
    $pen.LineJoin = 'Round'
    # 屏幕
    $sx = $s * 0.18; $sy = $s * 0.22; $sw = $s * 0.64; $sh = $s * 0.42
    $screen = RoundRect $sx $sy $sw $sh ($s * 0.06)
    $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 255, 255, 255))), $screen)
    $g.DrawPath($pen, $screen)
    # 支架和底座
    $cx = $s / 2
    $g.DrawLine($pen, $cx, $sy + $sh, $cx, $s * 0.76)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawLine($pen, $s * 0.34, $s * 0.78, $s * 0.66, $s * 0.78)
    # 屏幕里的虚线框，表示“虚拟”
    if ($s -ge 32) {
        $dash = New-Object System.Drawing.Pen($white, [Math]::Max(1, $s * 0.035))
        $dash.DashStyle = 'Dash'
        $g.DrawRectangle($dash, $sx + $sw * 0.22, $sy + $sh * 0.25, $sw * 0.56, $sh * 0.5)
    }
    $g.Dispose()
    return $bmp
}

# 一个 ICO 条目：64 及以上用 PNG（体积小），更小的用传统 32 位位图（兼容性最好）
function Get-IconEntry([int]$s) {
    $bmp = New-IconPng $s
    $ms = New-Object IO.MemoryStream
    if ($s -ge 64) {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    } else {
        $w = New-Object IO.BinaryWriter($ms)
        $maskRow = [int][Math]::Ceiling($s / 32) * 4
        $w.Write([UInt32]40); $w.Write([Int32]$s); $w.Write([Int32]($s * 2))
        $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]0)
        $w.Write([UInt32]($s * $s * 4 + $maskRow * $s)); $w.Write([Int32]0); $w.Write([Int32]0); $w.Write([UInt32]0); $w.Write([UInt32]0)
        $data = $bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $s, $s)), 'ReadOnly', 'Format32bppArgb')
        $row = New-Object byte[] ($s * 4)
        for ($y = $s - 1; $y -ge 0; $y--) {      # 位图按自下而上存储
            [Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row, 0, $s * 4)
            $w.Write($row)
        }
        $bmp.UnlockBits($data)
        $w.Write((New-Object byte[] ($maskRow * $s)))   # AND 掩码全 0，透明度由 alpha 通道决定
        $w.Flush()
    }
    $bmp.Dispose()
    return , $ms.ToArray()
}

# ICO 文件：多尺寸条目
$ico = Join-Path $root 'VDDManager.ico'
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) { , (Get-IconEntry $s) }
$fs = [IO.File]::Create($ico)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $b = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]$len); $bw.Write([UInt32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()
Write-Host "图标：$ico"

# ---------- 启动器 ----------
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { throw "找不到 C# 编译器：$csc" }
$exe = Join-Path $root 'VDDManager.exe'
& $csc /nologo /target:winexe /optimize+ /utf8output /codepage:65001 "/win32icon:$ico" "/out:$exe" `
    /reference:System.Windows.Forms.dll (Join-Path $root 'launcher\VDDManager.cs')
if ($LASTEXITCODE -ne 0) { throw "编译失败（代码 $LASTEXITCODE）" }
Write-Host "启动器：$exe"

# ---------- 打包 ----------
if ($Package) {
    $dist = Join-Path $root 'dist'
    $stage = Join-Path $dist 'VDD-Manager-CN'
    Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $root 'VDDManager.exe'), (Join-Path $root 'VDDManager.ps1'), $ico, (Join-Path $root 'README.md') $stage
    $zip = Join-Path $dist 'VDD-Manager-CN.zip'
    Compress-Archive -Path $stage -DestinationPath $zip -Force
    Write-Host "发布包：$zip"
}
