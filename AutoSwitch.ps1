<#
.SYNOPSIS
    自动切换虚拟屏：
      - 有实体显示器（笔记本内屏或外接屏）接入时，启用实体屏并断开 VDD 虚拟屏；
      - 实体显示器都不可用时（例如合盖远程），接回 VDD 虚拟屏。
    只在实体显示器接入 / 拔出的那一刻动作，之后手动调整的布局不会被覆盖。
    由计划任务 VDDAutoSwitch 在登录时启动（VDDManager.exe --autoswitch），也可以用 -Once 只检查一次。
#>
param([switch]$Once)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DisplayTopology.cs')))
Add-Type -Namespace VddCn -Name CtrlC -MemberDefinition @'
delegate bool Handler(int ctrlType);
[DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(Handler h, bool add);
static Handler keep;
// 忽略 Ctrl+C / Ctrl+Break，避免后台进程被外部控制台事件意外结束
public static void IgnoreCtrlC() { keep = t => t == 0 || t == 1; SetConsoleCtrlHandler(keep, true); }
'@

$AppDir  = Join-Path $env:APPDATA 'VDDManagerCN'
$LogFile = Join-Path $AppDir 'autoswitch.log'
New-Item -ItemType Directory -Force $AppDir | Out-Null

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
        if ((Get-Item $LogFile).Length -gt 256KB) {
            $keep = Get-Content $LogFile -Tail 500 -Encoding UTF8
            Set-Content $LogFile $keep -Encoding UTF8
        }
    } catch {}
}

function Get-State {
    $all = [VddCn.Topology]::GetTargets()
    $phys = @($all | Where-Object { -not $_.IsVirtual -and $_.Available })
    $vdd  = @($all | Where-Object { $_.IsVdd })
    [pscustomobject]@{
        Physical       = $phys
        PhysicalActive = @($phys | Where-Object Active)
        Vdd            = $vdd
        VddActive      = @($vdd | Where-Object Active)
        Key            = (@($phys | ForEach-Object Key | Sort-Object) -join ',')
    }
}

function Describe($s) {
    $p = if ($s.Physical.Count) { ($s.Physical | ForEach-Object { "$($_.Label)$(if ($_.Active) { '·已启用' } else { '·未启用' })" }) -join '，' } else { '无' }
    $v = if (-not $s.Vdd.Count) { '未检测到' } elseif ($s.VddActive.Count) { '已启用' } else { '已断开' }
    "实体显示器：$p；虚拟屏：$v"
}

# 切到实体屏：先把所有已连接的显示器都启用，再断开虚拟屏
function Switch-ToPhysical($s) {
    if (-not $s.PhysicalActive.Count) {
        $r = [VddCn.Topology]::ExtendAll()
        Write-Log "启用所有已连接的显示器，结果 $r"
        Start-Sleep -Milliseconds 1500
        $s = Get-State
    }
    if ($s.VddActive.Count -and $s.PhysicalActive.Count) {
        $r = [VddCn.Topology]::DetachVdd()
        Write-Log "断开虚拟屏，结果 $r"
    }
}

# 接回虚拟屏：只剩虚拟屏可用时，“扩展”就等于启用它
function Switch-ToVirtual($s) {
    if ($s.Vdd.Count -and -not $s.VddActive.Count) {
        $r = [VddCn.Topology]::ExtendAll()
        Write-Log "实体显示器都不可用，接回虚拟屏，结果 $r"
    }
}

function Invoke-Check([bool]$force) {
    $s = Get-State
    $changed = $s.Key -ne $script:lastKey
    if ($changed -or $force) {
        if ($changed -and $null -ne $script:lastKey) { Write-Log "显示器变化：$(Describe $s)" }
        if ($s.Physical.Count) { Switch-ToPhysical $s } else { Switch-ToVirtual $s }
        $script:lastKey = $s.Key
    } elseif (-not $s.Physical.Count -and $s.Vdd.Count -and -not $s.VddActive.Count) {
        # 兜底：没有实体屏时虚拟屏被断开了（比如远程时误操作），立刻接回，避免完全没有画面
        Switch-ToVirtual $s
    }
}

$script:lastKey = $null
if ($Once) {
    Write-Log "手动检查：$(Describe (Get-State))"
    Invoke-Check $true
    exit 0
}

$mutex = New-Object Threading.Mutex($false, 'Local\VDDManagerCN_AutoSwitch')
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }
[VddCn.CtrlC]::IgnoreCtrlC()
Set-Content (Join-Path $AppDir 'autoswitch.pid') $PID -Encoding ASCII

$s = Get-State
Write-Log "自动切换已启动。$(Describe $s)"
Invoke-Check $true
while ($true) {
    Start-Sleep -Seconds 3
    try { Invoke-Check $false } catch { Write-Log "出错：$($_.Exception.Message)" }
}
