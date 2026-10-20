<#
.SYNOPSIS
    Virtual Display Driver（VDD）中文管理器。
    只通过公开接口管理 VDD：vdd_settings.xml、驱动命名管道、pnputil / devcon、Windows 显示 API。
    双击 VDDManager.exe 启动（不显示控制台窗口）。
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# 只允许打开一个窗口
$mutex = New-Object Threading.Mutex($false, 'Local\VDDManagerCN')
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    [void][Windows.MessageBox]::Show('虚拟显示器管理器已经打开了。', '虚拟显示器管理器', 'OK', 'Information')
    exit
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace VddCn
{
    public class DisplayInfo
    {
        public string Name { get; set; }
        public string Device { get; set; }
        public string Adapter { get; set; }
        public bool Primary { get; set; }
        public bool IsVirtual { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public int Hz { get; set; }
        public int X { get; set; }
        public int Y { get; set; }
        public string Resolution { get { return Width + " × " + Height + " @ " + Hz + "Hz"; } }
        public string Kind { get { return IsVirtual ? "虚拟屏" : "其他显示器"; } }
        public string PrimaryText { get { return Primary ? "✔ 主显示器" : ""; } }
        public string Position { get { return "(" + X + ", " + Y + ")"; } }
    }

    public class ResRow
    {
        public int Width { get; set; }
        public int Height { get; set; }
        public int Hz { get; set; }
    }

    public static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
            public int dmPanningWidth, dmPanningHeight;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string device, int devNum, ref DISPLAY_DEVICE dd, int flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string device, int modeNum, ref DEVMODE dm);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
        static extern int ChangeDisplaySettingsExApply(string device, IntPtr dm, IntPtr hwnd, int flags, IntPtr lParam);

        public const string VddAdapter = "Virtual Display Driver";
        const int ATTACHED = 0x1, PRIMARY = 0x4;
        const int DM_POSITION = 0x20, DM_PELSWIDTH = 0x80000, DM_PELSHEIGHT = 0x100000, DM_DISPLAYFREQUENCY = 0x400000;
        const int CDS_UPDATEREGISTRY = 0x1, CDS_SET_PRIMARY = 0x10, CDS_NORESET = 0x10000000;

        static DEVMODE NewMode()
        {
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            return dm;
        }

        static IEnumerable<DISPLAY_DEVICE> Adapters()
        {
            for (int i = 0; i < 64; i++)
            {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref dd, 0)) yield break;
                yield return dd;
            }
        }

        static bool IsVdd(DISPLAY_DEVICE dd)
        {
            return dd.DeviceString.IndexOf(VddAdapter, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        // 驱动是否加载（有它的显示输出，不论是否接入桌面）
        public static bool HasVddAdapter()
        {
            foreach (var dd in Adapters()) if (IsVdd(dd)) return true;
            return false;
        }

        // 当前接入桌面的所有显示器
        public static List<DisplayInfo> GetDisplays()
        {
            var list = new List<DisplayInfo>();
            int v = 0;
            foreach (var dd in Adapters())
            {
                if ((dd.StateFlags & ATTACHED) == 0) continue;
                DEVMODE dm = NewMode();
                if (!EnumDisplaySettings(dd.DeviceName, -1, ref dm)) continue;
                bool isV = IsVdd(dd);
                list.Add(new DisplayInfo {
                    Name = isV ? "虚拟屏 " + (++v) : dd.DeviceString,
                    Device = dd.DeviceName, Adapter = dd.DeviceString,
                    Primary = (dd.StateFlags & PRIMARY) != 0, IsVirtual = isV,
                    Width = dm.dmPelsWidth, Height = dm.dmPelsHeight, Hz = dm.dmDisplayFrequency,
                    X = dm.dmPositionX, Y = dm.dmPositionY });
            }
            return list;
        }

        // {宽, 高, 刷新率}
        public static int[] GetCurrent(string device)
        {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, -1, ref dm)) return null;
            return new int[] { dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency };
        }

        // 去重后的所有模式，按宽、高、刷新率从大到小
        public static List<int[]> GetModes(string device)
        {
            var seen = new HashSet<string>();
            var list = new List<int[]>();
            DEVMODE dm = NewMode();
            for (int i = 0; EnumDisplaySettings(device, i, ref dm); i++)
            {
                string k = dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency;
                if (seen.Add(k)) list.Add(new int[] { dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency });
            }
            list.Sort((a, b) => a[0] != b[0] ? b[0] - a[0] : a[1] != b[1] ? b[1] - a[1] : b[2] - a[2]);
            return list;
        }

        // 返回 0 成功；1 需要重启；负数失败
        public static int SetMode(string device, int w, int h, int hz)
        {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, -1, ref dm)) return -100;
            dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmDisplayFrequency = hz;
            dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
            return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
        }

        // 把 device 设为主显示器：所有显示器整体平移，使它位于 (0,0)
        public static int SetPrimary(string device)
        {
            var all = GetDisplays();
            DisplayInfo target = all.Find(d => d.Device == device);
            if (target == null) return -101;
            foreach (var d in all)
            {
                DEVMODE dm = NewMode();
                if (!EnumDisplaySettings(d.Device, -1, ref dm)) return -100;
                dm.dmPositionX = d.X - target.X;
                dm.dmPositionY = d.Y - target.Y;
                dm.dmFields = DM_POSITION;
                int flags = CDS_UPDATEREGISTRY | CDS_NORESET;
                if (d.Device == device) flags |= CDS_SET_PRIMARY;
                int r = ChangeDisplaySettingsEx(d.Device, ref dm, IntPtr.Zero, flags, IntPtr.Zero);
                if (r != 0) return r;
            }
            return ChangeDisplaySettingsExApply(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        }
    }
}
'@

# ================= 路径与配置 =================
$AppDir    = Join-Path $env:APPDATA 'VDDManagerCN'
$BackupDir = Join-Path $AppDir 'Backups'
$AppConfig = Join-Path $AppDir 'config.json'
$PipeName  = 'MTTVirtualDisplayPipe'
$HwId      = 'Root\MttVDD'

$ConfDir = 'C:\VirtualDisplayDriver'
try {
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' -ErrorAction Stop
    if ($p.VDDPATH) { $ConfDir = $p.VDDPATH }
} catch {}
$SettingsFile = Join-Path $ConfDir 'vdd_settings.xml'

function Get-AppConfig {
    try { Get-Content $AppConfig -Raw -Encoding UTF8 | ConvertFrom-Json } catch { [pscustomobject]@{ PackageDir = '' } }
}
function Save-AppConfig($cfg) {
    New-Item -ItemType Directory -Force $AppDir | Out-Null
    $cfg | ConvertTo-Json | Set-Content $AppConfig -Encoding UTF8
}

# 驱动安装包：MttVDD.inf + devcon.exe（winget / VDD Control 自带）
function Find-DriverPackage {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x86' }   # 官方包里 x86 目录即 64 位版
    $dirs = @()
    $cfg = Get-AppConfig
    if ($cfg.PackageDir -and (Test-Path $cfg.PackageDir)) { $dirs += $cfg.PackageDir }
    $dirs += @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\VirtualDrivers.Virtual-Display-Driver*" -Directory -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty FullName)
    foreach ($d in $dirs) {
        $infs = @(Get-ChildItem $d -Recurse -Depth 4 -Filter 'MttVDD.inf' -ErrorAction SilentlyContinue)
        if (-not $infs) { continue }
        $inf = ($infs | Where-Object { $_.FullName -match "\\$arch\\" } | Select-Object -First 1)
        if (-not $inf) { $inf = $infs[0] }
        $devcon = Get-ChildItem $d -Recurse -Depth 3 -Filter 'devcon.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        return [pscustomobject]@{ Dir = $d; Inf = $inf.FullName; Devcon = if ($devcon) { $devcon.FullName } else { $null } }
    }
    return $null
}

# 驱动状态：直接读注册表（毫秒级），不用 Get-PnpDevice（WMI，可能要好几秒）
function Get-DriverStatus {
    $s = [pscustomobject]@{ Installed = $false; Disabled = $false; Running = $false; InstanceId = $null; Version = $null; Date = $null }
    foreach ($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not ($p.HardwareID -match 'MttVDD')) { continue }
        $s.Installed = $true
        $s.InstanceId = "ROOT\DISPLAY\$($k.PSChildName)"
        $s.Disabled = [bool]($p.ConfigFlags -band 0x1)
        if ($p.Driver) {
            $c = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($p.Driver)" -ErrorAction SilentlyContinue
            if ($c) { $s.Version = $c.DriverVersion; $s.Date = $c.DriverDate }
        }
        break
    }
    $s.Running = [VddCn.Native]::HasVddAdapter()
    return $s
}

# ================= 驱动命名管道 =================
function Test-VddPipe {
    try { [IO.Directory]::GetFiles('\\.\pipe\') -contains "\\.\pipe\$PipeName" } catch { $false }
}
function Send-VddPipe([string]$cmd) {
    $p = New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $p.Connect(1500)
        $b = [Text.Encoding]::Unicode.GetBytes($cmd)
        $p.Write($b, 0, $b.Length); $p.Flush()
        return $true
    } catch { return $false } finally { $p.Dispose() }
}

# ================= vdd_settings.xml =================
function Get-Settings {
    if (-not (Test-Path $SettingsFile)) { return $null }
    $x = New-Object Xml.XmlDocument
    $x.Load($SettingsFile)
    return $x
}
function Backup-Settings {
    if (-not (Test-Path $SettingsFile)) { return }
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    Copy-Item $SettingsFile (Join-Path $BackupDir ('vdd_settings_{0:yyyyMMdd_HHmmss_fff}.xml' -f (Get-Date))) -Force
    Get-ChildItem $BackupDir -Filter 'vdd_settings_*.xml' | Sort-Object Name -Descending | Select-Object -Skip 20 | Remove-Item -Force
}
function Save-Settings([Xml.XmlDocument]$x) {
    Backup-Settings
    $ws = New-Object Xml.XmlWriterSettings
    $ws.Indent = $true; $ws.IndentChars = '    '; $ws.Encoding = New-Object Text.UTF8Encoding($false)
    $w = [Xml.XmlWriter]::Create($SettingsFile, $ws)
    try { $x.Save($w) } finally { $w.Close() }
}
function Get-Node([Xml.XmlDocument]$x, [string]$path) {
    # 逐级找节点，不存在就创建
    $node = $x.DocumentElement
    foreach ($name in ($path -split '/')) {
        $child = $node.SelectSingleNode($name)
        if (-not $child) { $child = $node.AppendChild($x.CreateElement($name)) }
        $node = $child
    }
    return $node
}
function Get-ConfiguredCount {
    try { [int](Get-Settings).SelectSingleNode('/vdd_settings/monitors/count').InnerText } catch { $null }
}

# ================= 界面 =================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="虚拟显示器管理器" Width="1000" Height="700" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F4F6F9"
        FontFamily="Microsoft YaHei UI" FontSize="13" Foreground="#1F2937"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1F2937"/>
      <Setter Property="BorderBrush" Value="#D0D5DD"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#FEF2F2"/>
      <Setter Property="BorderBrush" Value="#FCA5A5"/>
      <Setter Property="Foreground" Value="#B91C1C"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E4E7EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="18,16"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Foreground" Value="#4B5563"/>
      <Setter Property="Margin" Value="0,0,12,8"/>
    </Style>
    <Style x:Key="Big" TargetType="TextBlock">
      <Setter Property="FontSize" Value="19"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,6,0,2"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="32"/>
      <Setter Property="MinWidth" Value="180"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="MaxDropDownHeight" Value="320"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="b" Background="White" BorderBrush="#D0D5DD" BorderThickness="1" CornerRadius="6">
                      <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#6B7280"
                                 HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#2563EB"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#2563EB"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="11,0,30,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"
                     IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Background="White" BorderBrush="#D0D5DD" BorderThickness="1" CornerRadius="6" Margin="0,3,0,0" Padding="0,4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Padding="11,7" Margin="4,0" CornerRadius="4" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="#EEF2FF"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Foreground" Value="#1D4ED8"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="32"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Padding" Value="6,0"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="BorderBrush" Value="#D0D5DD"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E4E7EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#EEF0F3"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeight" Value="32"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F9FAFB"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#4B5563"/>
      <Setter Property="BorderBrush" Value="#E4E7EC"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#E0EAFF"/>
          <Setter Property="Foreground" Value="#1F2937"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="NavItem" TargetType="ListBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Padding="14,10" Margin="10,2" CornerRadius="8" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F1F5F9"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E0EAFF"/>
                <Setter Property="Foreground" Value="#1D4ED8"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="210"/>
      <ColumnDefinition/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 左侧导航 -->
    <Border Grid.RowSpan="2" Background="White" BorderBrush="#E4E7EC" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="22,24,20,20">
          <TextBlock Text="虚拟显示器" FontSize="19" FontWeight="Bold"/>
          <TextBlock Text="Virtual Display Driver 中文管理" Foreground="#9CA3AF" FontSize="11" Margin="0,3,0,0"/>
        </StackPanel>
        <TextBlock x:Name="NavFooter" DockPanel.Dock="Bottom" Margin="22,0,18,16" Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap"/>
        <ListBox x:Name="Nav" BorderThickness="0" Background="Transparent" ItemContainerStyle="{StaticResource NavItem}">
          <ListBoxItem><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" Width="26" VerticalAlignment="Center"/><TextBlock Text="概览"/></StackPanel></ListBoxItem>
          <ListBoxItem><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" Width="26" VerticalAlignment="Center"/><TextBlock Text="显示设置"/></StackPanel></ListBoxItem>
          <ListBoxItem><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8AB;" FontFamily="Segoe MDL2 Assets" Width="26" VerticalAlignment="Center"/><TextBlock Text="自动切换"/></StackPanel></ListBoxItem>
          <ListBoxItem><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8FD;" FontFamily="Segoe MDL2 Assets" Width="26" VerticalAlignment="Center"/><TextBlock Text="可选分辨率"/></StackPanel></ListBoxItem>
          <ListBoxItem><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" Width="26" VerticalAlignment="Center"/><TextBlock Text="驱动选项"/></StackPanel></ListBoxItem>
          <ListBoxItem><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE90F;" FontFamily="Segoe MDL2 Assets" Width="26" VerticalAlignment="Center"/><TextBlock Text="驱动管理"/></StackPanel></ListBoxItem>
          <ListBoxItem><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE943;" FontFamily="Segoe MDL2 Assets" Width="26" VerticalAlignment="Center"/><TextBlock Text="配置文件"/></StackPanel></ListBoxItem>
        </ListBox>
      </DockPanel>
    </Border>

    <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
      <Grid Margin="30,26,30,14">

        <!-- 概览 -->
        <StackPanel x:Name="Page0">
          <TextBlock Style="{StaticResource H1}" Text="概览"/>
          <TextBlock Style="{StaticResource Sub}" Text="虚拟显示器驱动和所有显示器的当前状态，每 3 秒自动刷新。"/>
          <UniformGrid Columns="3">
            <Border Style="{StaticResource Card}" Margin="0,0,12,14">
              <StackPanel>
                <TextBlock Text="驱动状态" Style="{StaticResource Hint}"/>
                <TextBlock x:Name="OvDriver" Style="{StaticResource Big}"/>
                <TextBlock x:Name="OvDriverSub" Style="{StaticResource Hint}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,12,14">
              <StackPanel>
                <TextBlock Text="虚拟屏" Style="{StaticResource Hint}"/>
                <TextBlock x:Name="OvVirtual" Style="{StaticResource Big}"/>
                <TextBlock x:Name="OvVirtualSub" Style="{StaticResource Hint}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="与驱动通信" Style="{StaticResource Hint}"/>
                <TextBlock x:Name="OvPipe" Style="{StaticResource Big}"/>
                <TextBlock x:Name="OvPipeSub" Style="{StaticResource Hint}"/>
              </StackPanel>
            </Border>
          </UniformGrid>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="当前在用的显示器"/>
              <DataGrid x:Name="OvGrid" IsReadOnly="True" SelectionMode="Single" MinHeight="70">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="名称" Binding="{Binding Name}" Width="1.4*"/>
                  <DataGridTextColumn Header="类型" Binding="{Binding Kind}" Width="*"/>
                  <DataGridTextColumn Header="分辨率" Binding="{Binding Resolution}" Width="1.9*"/>
                  <DataGridTextColumn Header="位置" Binding="{Binding Position}" Width="0.9*"/>
                  <DataGridTextColumn Header="主显示器" Binding="{Binding PrimaryText}" Width="*"/>
                  <DataGridTextColumn Header="设备" Binding="{Binding Device}" Width="1.2*"/>
                </DataGrid.Columns>
              </DataGrid>
              <TextBlock x:Name="OvEmpty" Style="{StaticResource Hint}" Margin="0,8,0,0" Visibility="Collapsed"
                         Text="没有接入桌面的显示器。"/>
            </StackPanel>
          </Border>
          <WrapPanel>
            <Button x:Name="OvRefresh" Content="刷新"/>
            <Button x:Name="OvReload" Content="重启驱动（重新读取配置）"/>
            <Button x:Name="OvWinSettings" Content="打开 Windows 显示设置"/>
          </WrapPanel>
        </StackPanel>

        <!-- 显示设置 -->
        <StackPanel x:Name="Page1" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="显示设置"/>
          <TextBlock Style="{StaticResource Sub}" Text="调整虚拟屏的分辨率和刷新率。应用后有 15 秒确认时间，不点“保留”会自动还原，避免黑屏后无法操作。"/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="分辨率和刷新率"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="70"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition/><RowDefinition/><RowDefinition/>
                </Grid.RowDefinitions>
                <TextBlock Style="{StaticResource Label}" Text="虚拟屏"/>
                <ComboBox x:Name="CmbDisplay" Grid.Column="1" MinWidth="300"/>
                <TextBlock Style="{StaticResource Label}" Grid.Row="1" Text="分辨率"/>
                <ComboBox x:Name="CmbRes" Grid.Row="1" Grid.Column="1" MinWidth="300"/>
                <TextBlock Style="{StaticResource Label}" Grid.Row="2" Text="刷新率"/>
                <ComboBox x:Name="CmbHz" Grid.Row="2" Grid.Column="1" MinWidth="300"/>
              </Grid>
              <TextBlock x:Name="DispCurrent" Style="{StaticResource Hint}" Margin="82,2,0,10"/>
              <WrapPanel Margin="82,0,0,0">
                <Button x:Name="BtnApplyMode" Style="{StaticResource PrimaryBtn}" Content="应用"/>
                <Button x:Name="BtnSetPrimary" Content="设为主显示器"/>
                <Button x:Name="BtnDispRefresh" Content="刷新"/>
              </WrapPanel>
              <TextBlock x:Name="DispNone" Style="{StaticResource Hint}" Visibility="Collapsed" Foreground="#B45309"
                         Text="现在没有在线的虚拟屏。请先到“驱动管理”确认驱动已安装并启用。"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="虚拟屏数量"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12"
                         Text="同时创建几块虚拟显示器。修改后驱动会重新加载，所有虚拟屏会短暂断开几秒。"/>
              <StackPanel Orientation="Horizontal">
                <ComboBox x:Name="CmbCount" MinWidth="110"/>
                <Button x:Name="BtnApplyCount" Style="{StaticResource PrimaryBtn}" Content="应用数量"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- 自动切换 -->
        <StackPanel x:Name="Page2" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="自动切换"/>
          <TextBlock Style="{StaticResource Sub}" Text="打开笔记本或接上外接屏时，自动改用实体显示器并断开虚拟屏；实体显示器都不可用时（比如合盖远程），自动接回虚拟屏。开启后在后台运行，每次登录自动启动，不需要管理员权限。"/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="状态" Style="{StaticResource Hint}"/>
              <TextBlock x:Name="AsState" Style="{StaticResource Big}"/>
              <TextBlock x:Name="AsStateSub" Style="{StaticResource Hint}" Margin="0,0,0,14"/>
              <WrapPanel>
                <Button x:Name="BtnAsEnable" Style="{StaticResource PrimaryBtn}" Content="开启自动切换"/>
                <Button x:Name="BtnAsDisable" Content="关闭自动切换"/>
                <Button x:Name="BtnAsCheck" Content="立即检查一次"/>
              </WrapPanel>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="现在检测到的显示器"/>
              <DataGrid x:Name="AsGrid" IsReadOnly="True" SelectionMode="Single" MinHeight="70">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="类型" Binding="{Binding Kind}" Width="*"/>
                  <DataGridTextColumn Header="名称" Binding="{Binding Name}" Width="1.4*"/>
                  <DataGridTextColumn Header="连接" Binding="{Binding AvailableText}" Width="0.8*"/>
                  <DataGridTextColumn Header="启用" Binding="{Binding ActiveText}" Width="1.4*"/>
                </DataGrid.Columns>
              </DataGrid>
              <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0"
                         Text="只在实体显示器接入或拔出的那一刻切换；之后你在 Windows 里手动调整的布局（比如保留虚拟屏当副屏）不会被改回去。"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="最近记录"/>
              <TextBox x:Name="AsLog" Height="150" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                       VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top" FontFamily="Consolas" FontSize="12"
                       Background="#F9FAFB"/>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- 可选分辨率 -->
        <StackPanel x:Name="Page3" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="可选分辨率"/>
          <TextBlock Style="{StaticResource Sub}" Text="这里列出的分辨率会出现在 Windows 和“显示设置”页的分辨率列表里。修改后点“保存并重启驱动”生效。"/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="分辨率列表"/>
              <DataGrid x:Name="ResGrid" Height="240" SelectionMode="Extended">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="宽度" Binding="{Binding Width}" Width="*"/>
                  <DataGridTextColumn Header="高度" Binding="{Binding Height}" Width="*"/>
                  <DataGridTextColumn Header="刷新率 (Hz)" Binding="{Binding Hz}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
              <TextBlock Style="{StaticResource Hint}" Margin="0,6,0,12" Text="双击单元格可以直接修改；按住 Ctrl 或 Shift 可以多选后一起删除。"/>
              <WrapPanel>
                <ComboBox x:Name="CmbPreset" MinWidth="200"/>
                <TextBox x:Name="TxtW" Width="72"/>
                <TextBlock Text="×" VerticalAlignment="Center" Margin="0,0,8,8"/>
                <TextBox x:Name="TxtH" Width="72"/>
                <TextBox x:Name="TxtHz" Width="56" Text="60"/>
                <TextBlock Text="Hz" VerticalAlignment="Center" Margin="0,0,14,8"/>
                <Button x:Name="BtnResAdd" Content="添加"/>
                <Button x:Name="BtnResDel" Style="{StaticResource DangerBtn}" Content="删除选中"/>
              </WrapPanel>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="通用刷新率"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12" Text="这些刷新率会自动套用到上面的每一个分辨率。"/>
              <StackPanel Orientation="Horizontal">
                <ListBox x:Name="GlobalList" Width="150" Height="130" SelectionMode="Extended" Margin="0,0,14,0" BorderBrush="#D0D5DD"/>
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBox x:Name="TxtGlobal" Width="70"/>
                    <TextBlock Text="Hz" VerticalAlignment="Center" Margin="0,0,10,8"/>
                    <Button x:Name="BtnGlobalAdd" Content="添加"/>
                  </StackPanel>
                  <Button x:Name="BtnGlobalDel" Style="{StaticResource DangerBtn}" Content="删除选中" HorizontalAlignment="Left"/>
                </StackPanel>
              </StackPanel>
            </StackPanel>
          </Border>
          <WrapPanel>
            <Button x:Name="BtnResSaveReload" Style="{StaticResource PrimaryBtn}" Content="保存并重启驱动"/>
            <Button x:Name="BtnResSave" Content="仅保存"/>
            <Button x:Name="BtnResReload" Content="放弃修改，重新读取"/>
          </WrapPanel>
        </StackPanel>

        <!-- 驱动选项 -->
        <StackPanel x:Name="Page4" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="驱动选项"/>
          <TextBlock Style="{StaticResource Sub}" Text="高级功能开关。不确定的保持默认即可，修改后点“保存并重启驱动”生效。"/>
          <Border Style="{StaticResource Card}">
            <StackPanel x:Name="OptPanel"/>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="渲染用的显卡"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12"
                         Text="填 default 表示自动选择。多显卡电脑可以填显卡名称（和设备管理器里显示的一样），让虚拟屏由指定显卡渲染。"/>
              <TextBox x:Name="TxtGpu" Width="340" HorizontalAlignment="Left"/>
            </StackPanel>
          </Border>
          <WrapPanel>
            <Button x:Name="BtnOptSaveReload" Style="{StaticResource PrimaryBtn}" Content="保存并重启驱动"/>
            <Button x:Name="BtnOptSave" Content="仅保存"/>
            <Button x:Name="BtnOptReload" Content="放弃修改，重新读取"/>
          </WrapPanel>
        </StackPanel>

        <!-- 驱动管理 -->
        <StackPanel x:Name="Page5" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="驱动管理"/>
          <TextBlock Style="{StaticResource Sub}" Text="禁用、启用、安装、卸载驱动需要管理员权限，点击后 Windows 会弹出授权窗口。"/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="驱动信息"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="96"/>
                  <ColumnDefinition/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
                </Grid.RowDefinitions>
                <TextBlock Style="{StaticResource Label}" Text="状态"/>
                <TextBlock x:Name="DrvState" Grid.Column="1" FontWeight="SemiBold" Margin="0,0,0,8" VerticalAlignment="Center"/>
                <TextBlock Style="{StaticResource Label}" Grid.Row="1" Text="版本"/>
                <TextBlock x:Name="DrvVersion" Grid.Row="1" Grid.Column="1" Margin="0,0,0,8" VerticalAlignment="Center"/>
                <TextBlock Style="{StaticResource Label}" Grid.Row="2" Text="设备实例"/>
                <TextBlock x:Name="DrvInstance" Grid.Row="2" Grid.Column="1" Margin="0,0,0,8" VerticalAlignment="Center"/>
                <TextBlock Style="{StaticResource Label}" Grid.Row="3" Text="安装包"/>
                <TextBlock x:Name="DrvPackage" Grid.Row="3" Grid.Column="1" Margin="0,0,8,8" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <Button x:Name="BtnPickPkg" Grid.Row="3" Grid.Column="2" Content="选择…" VerticalAlignment="Center" Padding="12,4"/>
                <TextBlock Style="{StaticResource Label}" Grid.Row="4" Text="配置文件"/>
                <TextBlock x:Name="DrvConf" Grid.Row="4" Grid.Column="1" Margin="0,0,0,8" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </Grid>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="操作"/>
              <WrapPanel>
                <Button x:Name="BtnDrvReload" Content="重启驱动"/>
                <Button x:Name="BtnDrvDisable" Content="禁用"/>
                <Button x:Name="BtnDrvEnable" Content="启用"/>
                <Button x:Name="BtnDrvInstall" Style="{StaticResource PrimaryBtn}" Content="安装"/>
                <Button x:Name="BtnDrvReinstall" Content="重新安装"/>
                <Button x:Name="BtnDrvUninstall" Style="{StaticResource DangerBtn}" Content="卸载"/>
              </WrapPanel>
              <TextBox x:Name="DrvLog" Height="130" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                       VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top" FontFamily="Consolas" FontSize="12"
                       Margin="0,4,0,0" Background="#F9FAFB"/>
            </StackPanel>
          </Border>
          <Border Background="#FFFBEB" BorderBrush="#FCD34D" BorderThickness="1" CornerRadius="10" Padding="16,12">
            <TextBlock TextWrapping="Wrap" Foreground="#92400E" LineHeight="20">
              <Run FontWeight="SemiBold" Text="注意："/>
              <Run Text="大版本更新显卡或芯片组驱动前，请先在这里卸载 VDD，更新完再安装。"/>
              <LineBreak/>
              <Run Text="如果开机黑屏：连续强制关机 2–3 次进入恢复环境 → 疑难解答 → 高级选项 → 启动设置 → 重启后按 F4 进入安全模式 → 设备管理器 → 显示适配器 → 卸载 Virtual Display Driver。"/>
            </TextBlock>
          </Border>
        </StackPanel>

        <!-- 配置文件 -->
        <StackPanel x:Name="Page6" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="配置文件"/>
          <TextBlock Style="{StaticResource Sub}" Text="直接编辑 vdd_settings.xml。保存前会自动检查格式，并备份旧文件。"/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock x:Name="RawPath" Style="{StaticResource Hint}" Margin="0,0,0,8"/>
              <TextBox x:Name="RawText" Height="360" AcceptsReturn="True" AcceptsTab="True" TextWrapping="NoWrap"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" VerticalContentAlignment="Top"
                       FontFamily="Consolas" FontSize="12" Padding="8,6"/>
              <WrapPanel Margin="0,4,0,0">
                <Button x:Name="BtnRawSaveReload" Style="{StaticResource PrimaryBtn}" Content="检查并保存，重启驱动"/>
                <Button x:Name="BtnRawSave" Content="检查并保存"/>
                <Button x:Name="BtnRawLoad" Content="重新读取"/>
                <Button x:Name="BtnRawNotepad" Content="用记事本打开"/>
                <Button x:Name="BtnRawFolder" Content="打开所在文件夹"/>
              </WrapPanel>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="备份"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12" Text="通过本程序保存配置前都会自动备份，保留最近 20 份。"/>
              <WrapPanel>
                <ComboBox x:Name="CmbBackup" MinWidth="320"/>
                <Button x:Name="BtnRestore" Content="恢复所选备份"/>
                <Button x:Name="BtnBackupFolder" Content="打开备份文件夹"/>
              </WrapPanel>
            </StackPanel>
          </Border>
        </StackPanel>

      </Grid>
    </ScrollViewer>

    <Border Grid.Column="1" Grid.Row="1" Background="White" BorderBrush="#E4E7EC" BorderThickness="0,1,0,0" Padding="30,8">
      <TextBlock x:Name="StatusText" Foreground="#6B7280" Text="就绪"/>
    </Border>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$icoFile = Join-Path $PSScriptRoot 'VDDManager.ico'
if (Test-Path $icoFile) { try { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoFile) } catch {} }
$ui = @{}
foreach ($n in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = ($n.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -First 1).Value
    $el = $win.FindName($name)
    if ($el) { $ui[$name] = $el }
}

$brush = @{
    Green = [Windows.Media.Brushes]::SeaGreen; Red = [Windows.Media.BrushConverter]::new().ConvertFrom('#DC2626')
    Amber = [Windows.Media.BrushConverter]::new().ConvertFrom('#D97706'); Gray = [Windows.Media.BrushConverter]::new().ConvertFrom('#6B7280')
    Text  = [Windows.Media.BrushConverter]::new().ConvertFrom('#1F2937')
}

# ================= 通用辅助 =================
function Set-Status([string]$msg, [string]$color = 'Gray') {
    $ui.StatusText.Text = '{0:HH:mm:ss}  {1}' -f (Get-Date), $msg
    $ui.StatusText.Foreground = $brush[$color]
}
function Ask([string]$msg, [string]$title = '请确认') {
    [Windows.MessageBox]::Show($win, $msg, $title, 'YesNo', 'Question') -eq 'Yes'
}
function Show-Error([string]$msg) { [void][Windows.MessageBox]::Show($win, $msg, '出错了', 'OK', 'Error') }
function Show-Info([string]$msg)  { [void][Windows.MessageBox]::Show($win, $msg, '提示', 'OK', 'Information') }
# 事件处理统一包一层，异常弹窗而不是让程序崩溃
function Safe([scriptblock]$sb) { try { & $sb } catch { Show-Error "$($_.Exception.Message)" } }
function New-Item-Combo([string]$text, $tag) {
    $i = New-Object Windows.Controls.ComboBoxItem
    $i.Content = $text; $i.Tag = $tag
    return $i
}
function Read-Int($box, [string]$name, [int]$min, [int]$max) {
    $v = 0
    if (-not [int]::TryParse($box.Text.Trim(), [ref]$v) -or $v -lt $min -or $v -gt $max) {
        throw "$name 要填 $min 到 $max 之间的整数。"
    }
    return $v
}

# 重启驱动：优先用驱动自己的管道命令（不需要管理员），不行再用 pnputil
function Invoke-DriverReload {
    if (Send-VddPipe 'RELOAD_DRIVER') {
        Set-Status '已通知驱动重新加载配置，屏幕可能会闪一下。' 'Green'
        $script:refreshIn = 4
        return
    }
    $st = Get-DriverStatus
    if (-not $st.InstanceId) { Show-Error '驱动没有安装，无法重启。'; return }
    if (Ask '无法通过管道联系驱动（驱动可能没在运行）。要用管理员权限重启设备吗？') {
        Start-AdminOp '重启驱动' "pnputil /restart-device '$($st.InstanceId)'; `$global:rc = if (`$LASTEXITCODE -in 0,3010) { 0 } else { `$LASTEXITCODE }"
    }
}

# ================= 管理员操作（后台进程，不阻塞界面）=================
$script:op = $null
function Start-AdminOp([string]$title, [string]$body) {
    if ($script:op) { Show-Info '上一个操作还没完成，请稍等。'; return }
    $log = Join-Path $env:TEMP 'vddcn-op.log'
    $ps1 = Join-Path $env:TEMP 'vddcn-op.ps1'
    Remove-Item $log -ErrorAction SilentlyContinue
    $content = @"
`$ErrorActionPreference = 'Continue'
`$global:rc = 0
& {
$body
} *>&1 | Out-File -FilePath '$log' -Encoding UTF8
exit `$global:rc
"@
    [IO.File]::WriteAllText($ps1, $content, (New-Object Text.UTF8Encoding($true)))
    try {
        $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru `
             -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps1`"")
    } catch {
        Set-Status "$title 已取消（没有获得管理员授权）。" 'Amber'
        return
    }
    $script:op = @{ Proc = $p; Title = $title; Log = $log }
    $ui.DrvLog.Text = "正在执行：$title …`r`n"
    Set-Status "正在执行：$title …" 'Amber'
    Update-DriverButtons
}
function Complete-AdminOp {
    $op = $script:op
    $script:op = $null
    $code = try { $op.Proc.ExitCode } catch { -1 }
    $out = if (Test-Path $op.Log) { (Get-Content $op.Log -Encoding UTF8) -join "`r`n" } else { '' }
    $ui.DrvLog.Text = "[$($op.Title)] 退出代码 $code`r`n$out"
    if ($code -eq 0) { Set-Status "$($op.Title) 完成。" 'Green' }
    else { Set-Status "$($op.Title) 失败（代码 $code），详情见`“驱动管理`”页的输出。" 'Red' }
    $script:refreshIn = 3
    Refresh-Driver
    Refresh-Overview
}

# ================= 概览 =================
$script:ovSig = ''
function Refresh-Overview {
    $st = Get-DriverStatus
    if (-not $st.Installed) { $ui.OvDriver.Text = '未安装'; $ui.OvDriver.Foreground = $brush.Red; $ui.OvDriverSub.Text = '到“驱动管理”页安装' }
    elseif ($st.Disabled)  { $ui.OvDriver.Text = '已禁用'; $ui.OvDriver.Foreground = $brush.Amber; $ui.OvDriverSub.Text = '到“驱动管理”页启用' }
    elseif ($st.Running)   { $ui.OvDriver.Text = '运行中'; $ui.OvDriver.Foreground = $brush.Green; $ui.OvDriverSub.Text = "版本 $($st.Version)" }
    else                   { $ui.OvDriver.Text = '已安装，未运行'; $ui.OvDriver.Foreground = $brush.Amber; $ui.OvDriverSub.Text = '可尝试重启驱动或重启电脑' }

    $disps = [VddCn.Native]::GetDisplays()
    $virt = @($disps | Where-Object IsVirtual)
    $conf = Get-ConfiguredCount
    $ui.OvVirtual.Text = "$($virt.Count) 块在线"
    $ui.OvVirtual.Foreground = if ($virt.Count) { $brush.Green } else { $brush.Gray }
    $ui.OvVirtualSub.Text = if ($null -ne $conf) { "配置文件里设置为 $conf 块" } else { '找不到配置文件' }

    if (Test-VddPipe) { $ui.OvPipe.Text = '正常'; $ui.OvPipe.Foreground = $brush.Green; $ui.OvPipeSub.Text = '可以直接重启驱动、改虚拟屏数量' }
    else { $ui.OvPipe.Text = '不可用'; $ui.OvPipe.Foreground = $brush.Gray; $ui.OvPipeSub.Text = '驱动没在运行时无法通信' }

    $sig = ($disps | ForEach-Object { "$($_.Device)|$($_.Resolution)|$($_.Position)|$($_.Primary)" }) -join ';'
    if ($sig -ne $script:ovSig) { $ui.OvGrid.ItemsSource = $disps; $script:ovSig = $sig }
    $ui.OvEmpty.Visibility = if ($disps.Count) { 'Collapsed' } else { 'Visible' }
}

# ================= 显示设置 =================
$script:loading = $false
function Refresh-DisplayPage {
    $script:loading = $true
    try {
        $prev = if ($ui.CmbDisplay.SelectedItem) { $ui.CmbDisplay.SelectedItem.Tag } else { $null }
        $ui.CmbDisplay.Items.Clear()
        $virt = @([VddCn.Native]::GetDisplays() | Where-Object IsVirtual)
        foreach ($d in $virt) {
            $label = "$($d.Name)（$($d.Device)）$(if ($d.Primary) { ' · 主显示器' })"
            [void]$ui.CmbDisplay.Items.Add((New-Item-Combo $label $d.Device))
        }
        $has = $virt.Count -gt 0
        foreach ($c in 'CmbDisplay', 'CmbRes', 'CmbHz', 'BtnApplyMode', 'BtnSetPrimary') { $ui[$c].IsEnabled = $has }
        $ui.DispNone.Visibility = if ($has) { 'Collapsed' } else { 'Visible' }
        if ($has) {
            $idx = 0
            for ($i = 0; $i -lt $ui.CmbDisplay.Items.Count; $i++) { if ($ui.CmbDisplay.Items[$i].Tag -eq $prev) { $idx = $i } }
            $ui.CmbDisplay.SelectedIndex = $idx
        } else {
            $ui.CmbRes.Items.Clear(); $ui.CmbHz.Items.Clear(); $ui.DispCurrent.Text = ''
        }

        $ui.CmbCount.Items.Clear()
        1..16 | ForEach-Object { [void]$ui.CmbCount.Items.Add((New-Item-Combo "$_ 块" $_)) }
        $conf = Get-ConfiguredCount
        $ui.CmbCount.SelectedIndex = if ($conf -ge 1 -and $conf -le 16) { $conf - 1 } else { 0 }
    } finally { $script:loading = $false }
    if ($ui.CmbDisplay.SelectedItem) { Load-Modes }
}

function Load-Modes {
    $dev = $ui.CmbDisplay.SelectedItem.Tag
    $cur = [VddCn.Native]::GetCurrent($dev)
    $script:modes = [VddCn.Native]::GetModes($dev)
    $ui.DispCurrent.Text = if ($cur) { "当前：$($cur[0]) × $($cur[1]) @ $($cur[2])Hz" } else { '' }
    $script:loading = $true
    try {
        $ui.CmbRes.Items.Clear()
        $seen = @{}
        foreach ($m in $script:modes) {
            $k = "$($m[0])x$($m[1])"
            if ($seen[$k]) { continue }
            $seen[$k] = $true
            $ratio = Get-Ratio $m[0] $m[1]
            [void]$ui.CmbRes.Items.Add((New-Item-Combo "$($m[0]) × $($m[1])$ratio" @($m[0], $m[1])))
            if ($cur -and $m[0] -eq $cur[0] -and $m[1] -eq $cur[1]) { $ui.CmbRes.SelectedIndex = $ui.CmbRes.Items.Count - 1 }
        }
        if ($ui.CmbRes.SelectedIndex -lt 0 -and $ui.CmbRes.Items.Count) { $ui.CmbRes.SelectedIndex = 0 }
    } finally { $script:loading = $false }
    Load-Rates
}

function Get-Ratio([int]$w, [int]$h) {
    $known = @{ '16:9' = 16/9; '16:10' = 16/10; '21:9' = 64/27; '4:3' = 4/3; '32:9' = 32/9; '9:16' = 9/16; '5:4' = 5/4 }
    foreach ($k in $known.Keys) { if ([math]::Abs($w / $h - $known[$k]) -lt 0.02) { return "（$k）" } }
    return ''
}

function Load-Rates {
    $ui.CmbHz.Items.Clear()
    if (-not $ui.CmbRes.SelectedItem) { return }
    $wh = $ui.CmbRes.SelectedItem.Tag
    $cur = [VddCn.Native]::GetCurrent($ui.CmbDisplay.SelectedItem.Tag)
    $rates = @($script:modes | Where-Object { $_[0] -eq $wh[0] -and $_[1] -eq $wh[1] } | ForEach-Object { $_[2] } | Sort-Object -Descending -Unique)
    foreach ($r in $rates) { [void]$ui.CmbHz.Items.Add((New-Item-Combo "$r Hz" $r)) }
    $pick = if ($cur -and $rates -contains $cur[2]) { $cur[2] } elseif ($rates -contains 60) { 60 } else { $rates[0] }
    for ($i = 0; $i -lt $ui.CmbHz.Items.Count; $i++) { if ($ui.CmbHz.Items[$i].Tag -eq $pick) { $ui.CmbHz.SelectedIndex = $i } }
}

# Windows 风格的“保留这些显示设置？”倒计时确认
function Confirm-Keep([int]$seconds = 15) {
    [xml]$cx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="保留这些显示设置？" Width="400" SizeToContent="Height" ResizeMode="NoResize" Topmost="True"
        WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI" FontSize="13" Background="White">
  <StackPanel Margin="24,20">
    <TextBlock Text="保留这些显示设置？" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,8"/>
    <TextBlock x:Name="Msg" TextWrapping="Wrap" Foreground="#4B5563"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button x:Name="Keep" Content="保留更改" Padding="18,7" Margin="0,0,8,0" Background="#2563EB" Foreground="White" BorderBrush="#2563EB"/>
      <Button x:Name="Revert" Content="还原" Padding="18,7"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $cx))
    $script:cfKeep = $false
    $script:cfLeft = $seconds
    $msg = $w.FindName('Msg')
    $msg.Text = "如果画面正常，请点`“保留更改`”。$($script:cfLeft) 秒后会自动还原。"
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(1)
    $t.Add_Tick({
        $script:cfLeft--
        $msg.Text = "如果画面正常，请点`“保留更改`”。$($script:cfLeft) 秒后会自动还原。"
        if ($script:cfLeft -le 0) { $t.Stop(); $w.Close() }
    })
    $w.FindName('Keep').Add_Click({ $script:cfKeep = $true; $t.Stop(); $w.Close() })
    $w.FindName('Revert').Add_Click({ $t.Stop(); $w.Close() })
    $t.Start()
    [void]$w.ShowDialog()
    $t.Stop()
    return $script:cfKeep
}

function Apply-Mode {
    $dev = $ui.CmbDisplay.SelectedItem.Tag
    $wh = $ui.CmbRes.SelectedItem.Tag
    $hz = $ui.CmbHz.SelectedItem.Tag
    $old = [VddCn.Native]::GetCurrent($dev)
    if ($old[0] -eq $wh[0] -and $old[1] -eq $wh[1] -and $old[2] -eq $hz) { Set-Status '已经是这个设置了。'; return }
    $r = [VddCn.Native]::SetMode($dev, $wh[0], $wh[1], $hz)
    if ($r -ne 0) { Show-Error "修改失败（代码 $r）。这个分辨率或刷新率可能不被支持。"; return }
    if (Confirm-Keep 15) {
        Set-Status "已应用 $($wh[0]) × $($wh[1]) @ ${hz}Hz。" 'Green'
    } else {
        [void][VddCn.Native]::SetMode($dev, $old[0], $old[1], $old[2])
        Set-Status "已还原为 $($old[0]) × $($old[1]) @ $($old[2])Hz。" 'Amber'
    }
    Refresh-DisplayPage
}

# ================= 自动切换 =================
$AsTaskName = 'VDDAutoSwitch'
$AsLogFile  = Join-Path $AppDir 'autoswitch.log'
$AsPidFile  = Join-Path $AppDir 'autoswitch.pid'
$script:hasTopology = $false
try {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DisplayTopology.cs')))
    $script:hasTopology = $true
} catch {}
$script:sched = $null
function Get-Scheduler {
    if (-not $script:sched) { $script:sched = New-Object -ComObject Schedule.Service; $script:sched.Connect() }
    return $script:sched
}
function Get-AsTask { try { (Get-Scheduler).GetFolder('\').GetTask($AsTaskName) } catch { $null } }
function Get-AsProcess {
    try {
        $id = [int](Get-Content $AsPidFile -ErrorAction Stop | Select-Object -First 1)
        $p = Get-Process -Id $id -ErrorAction Stop
        if ($p.ProcessName -eq 'powershell') { return $p }
    } catch {}
    return $null
}
function Enable-AutoSwitch {
    $exe = Join-Path $PSScriptRoot 'VDDManager.exe'
    if (Test-Path $exe) { $cmd = $exe; $arg = '--autoswitch' }
    else {
        $cmd = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arg = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'AutoSwitch.ps1')`""
    }
    $e = { param($s) [Security.SecurityElement]::Escape($s) }
    $user = & $e "$env:USERDOMAIN\$env:USERNAME"
    # 登录时启动；另有每分钟一次的保活触发器，进程还在时会被忽略，意外退出后 1 分钟内自动拉起
    $xml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>VDD 中文管理器：有实体显示器时断开虚拟屏，没有时接回虚拟屏。</Description></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$user</UserId></LogonTrigger>
    <TimeTrigger>
      <Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'))</StartBoundary><Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>$(& $e $cmd)</Command><Arguments>$(& $e $arg)</Arguments><WorkingDirectory>$(& $e $PSScriptRoot)</WorkingDirectory></Exec>
  </Actions>
</Task>
"@
    [void](Get-Scheduler).GetFolder('\').RegisterTask($AsTaskName, $xml, 6, $null, $null, 3)
    [void](Get-AsTask).Run($null)
}
function Disable-AutoSwitch {
    $t = Get-AsTask
    if ($t) { try { $t.Stop(0) } catch {}; (Get-Scheduler).GetFolder('\').DeleteTask($AsTaskName, 0) }
    $p = Get-AsProcess
    if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $AsPidFile -ErrorAction SilentlyContinue
}
$script:asSig = ''
function Refresh-AutoSwitch {
    if (-not $script:hasTopology) {
        $ui.AsState.Text = '不可用'; $ui.AsState.Foreground = $brush.Red
        $ui.AsStateSub.Text = '缺少 DisplayTopology.cs，请重新下载完整的程序包。'
        foreach ($b in 'BtnAsEnable', 'BtnAsDisable', 'BtnAsCheck') { $ui[$b].IsEnabled = $false }
        return
    }
    $t = Get-AsTask
    $p = Get-AsProcess
    if (-not $t) {
        $ui.AsState.Text = '未开启'; $ui.AsState.Foreground = $brush.Gray
        $ui.AsStateSub.Text = '开启后会立即开始工作，以后每次登录自动启动。'
    } elseif ($p) {
        $ui.AsState.Text = '已开启 · 正在运行'; $ui.AsState.Foreground = $brush.Green
        $ui.AsStateSub.Text = "后台每 3 秒检查一次显示器（进程 $($p.Id)）。"
    } else {
        $ui.AsState.Text = '已开启 · 未运行'; $ui.AsState.Foreground = $brush.Amber
        $ui.AsStateSub.Text = '1 分钟内会自动拉起；也可以关闭后重新开启。'
    }
    $ui.BtnAsEnable.IsEnabled = -not $t
    $ui.BtnAsDisable.IsEnabled = [bool]$t
    $ui.BtnAsCheck.IsEnabled = $true

    $targets = [VddCn.Topology]::GetTargets()
    $sig = ($targets | ForEach-Object { "$($_.Key)|$($_.Available)|$($_.Active)|$($_.Gdi)" }) -join ';'
    if ($sig -ne $script:asSig) { $ui.AsGrid.ItemsSource = $targets; $script:asSig = $sig }

    $log = if (Test-Path $AsLogFile) { (Get-Content $AsLogFile -Tail 40 -Encoding UTF8) -join "`r`n" } else { '（还没有记录）' }
    if ($ui.AsLog.Text -ne $log) { $ui.AsLog.Text = $log; $ui.AsLog.ScrollToEnd() }
}

# ================= 可选分辨率 =================
$script:resRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[VddCn.ResRow]'
$ui.ResGrid.ItemsSource = $script:resRows
$script:resDirty = $false
function Load-ResPage {
    $script:resRows.Clear(); $ui.GlobalList.Items.Clear()
    $x = Get-Settings
    if (-not $x) { Set-Status "找不到配置文件 $SettingsFile" 'Red'; return }
    foreach ($n in $x.SelectNodes('/vdd_settings/resolutions/resolution')) {
        $r = New-Object VddCn.ResRow
        $r.Width = [int]$n.width; $r.Height = [int]$n.height; $r.Hz = [int]$n.refresh_rate
        $script:resRows.Add($r)
    }
    foreach ($n in $x.SelectNodes('/vdd_settings/global/g_refresh_rate')) { [void]$ui.GlobalList.Items.Add([int]$n.InnerText) }
    $script:resDirty = $false
}
function Save-ResPage {
    [void]$ui.ResGrid.CommitEdit()
    if ($script:resRows.Count -eq 0) { throw '至少要保留一个分辨率。' }
    $x = Get-Settings
    $res = Get-Node $x 'resolutions'
    foreach ($n in @($res.SelectNodes('resolution'))) { [void]$res.RemoveChild($n) }
    foreach ($r in $script:resRows) {
        if ($r.Width -lt 320 -or $r.Height -lt 200 -or $r.Hz -lt 1) { throw "分辨率 $($r.Width)×$($r.Height)@$($r.Hz) 不合法。" }
        $e = $x.CreateElement('resolution')
        foreach ($kv in @(@('width', $r.Width), @('height', $r.Height), @('refresh_rate', $r.Hz))) {
            $c = $x.CreateElement($kv[0]); $c.InnerText = [string]$kv[1]; [void]$e.AppendChild($c)
        }
        [void]$res.AppendChild($e)
    }
    $g = Get-Node $x 'global'
    foreach ($n in @($g.SelectNodes('g_refresh_rate'))) { [void]$g.RemoveChild($n) }
    foreach ($v in $ui.GlobalList.Items) { $c = $x.CreateElement('g_refresh_rate'); $c.InnerText = [string]$v; [void]$g.AppendChild($c) }
    Save-Settings $x
    $script:resDirty = $false
    Set-Status '分辨率列表已保存。' 'Green'
}

$presets = @(
    @('720p', 1280, 720), @('1366 × 768', 1366, 768), @('1600 × 900', 1600, 900), @('1080p', 1920, 1080),
    @('1920 × 1200（16:10）', 1920, 1200), @('2560 × 1080（21:9）', 2560, 1080), @('2K', 2560, 1440),
    @('2560 × 1600（16:10）', 2560, 1600), @('3440 × 1440（21:9）', 3440, 1440), @('4K', 3840, 2160),
    @('3840 × 2400（16:10）', 3840, 2400), @('1080 × 1920（竖屏）', 1080, 1920)
)
[void]$ui.CmbPreset.Items.Add((New-Item-Combo '常用分辨率…' $null))
foreach ($p in $presets) {
    $label = if ($p[0] -match '×') { $p[0] } else { "$($p[0])（$($p[1]) × $($p[2])）" }
    [void]$ui.CmbPreset.Items.Add((New-Item-Combo $label @($p[1], $p[2])))
}
$ui.CmbPreset.SelectedIndex = 0

# ================= 驱动选项 =================
$options = @(
    @('HardwareCursor', '硬件光标', '由显卡直接绘制鼠标，移动更流畅。推荐开启。'),
    @('SDR10bit', 'SDR 10 位色深', '标准动态范围下使用 10 位色。和 HDR+ 不能同时开启。'),
    @('HDRPlus', 'HDR+（12 位）', '需要 Windows 11 23H2 或更新版本。和 SDR 10 位不能同时开启。'),
    @('CustomEdid', '使用自定义 EDID', '读取配置文件夹里的 user_edid.bin，模拟某台真实显示器。不支持模拟分辨率。'),
    @('PreventSpoof', '防止厂商信息伪装', '配合自定义 EDID 使用，仅在确实需要时开启。'),
    @('EdidCeaOverride', '覆盖 EDID CEA 扩展块', '配合自定义 EDID 启用 HDR。'),
    @('logging', '记录日志', '把驱动运行情况写到配置文件夹的 Logs 里，用于排查问题。'),
    @('debuglogging', '调试日志', '会产生大量日志，只在排错时短时间开启。')
)
$script:optBoxes = @{}
foreach ($o in $options) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,0,0,12'
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Content = $o[1]; $cb.FontWeight = 'SemiBold'; $cb.VerticalContentAlignment = 'Center'
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $o[2]; $tb.Foreground = $brush.Gray; $tb.FontSize = 12; $tb.Margin = '20,2,0,0'; $tb.TextWrapping = 'Wrap'
    [void]$sp.Children.Add($cb); [void]$sp.Children.Add($tb)
    [void]$ui.OptPanel.Children.Add($sp)
    $script:optBoxes[$o[0]] = $cb
}
function Load-OptPage {
    $x = Get-Settings
    if (-not $x) { Set-Status "找不到配置文件 $SettingsFile" 'Red'; return }
    foreach ($k in $script:optBoxes.Keys) {
        $n = $x.SelectSingleNode("/vdd_settings/options/$k")
        $script:optBoxes[$k].IsChecked = ($n -and $n.InnerText.Trim() -eq 'true')
    }
    $g = $x.SelectSingleNode('/vdd_settings/gpu/friendlyname')
    $ui.TxtGpu.Text = if ($g) { $g.InnerText } else { 'default' }
}
function Save-OptPage {
    if ($script:optBoxes.SDR10bit.IsChecked -and $script:optBoxes.HDRPlus.IsChecked) { throw 'SDR 10 位和 HDR+ 不能同时开启。' }
    $x = Get-Settings
    foreach ($k in $script:optBoxes.Keys) {
        (Get-Node $x "options/$k").InnerText = if ($script:optBoxes[$k].IsChecked) { 'true' } else { 'false' }
    }
    $gpu = $ui.TxtGpu.Text.Trim()
    (Get-Node $x 'gpu/friendlyname').InnerText = if ($gpu) { $gpu } else { 'default' }
    Save-Settings $x
    Set-Status '驱动选项已保存。' 'Green'
}

# ================= 驱动管理 =================
function Refresh-Driver {
    $st = Get-DriverStatus
    $script:drv = $st
    if (-not $st.Installed) { $ui.DrvState.Text = '未安装'; $ui.DrvState.Foreground = $brush.Red }
    elseif ($st.Disabled)  { $ui.DrvState.Text = '已禁用'; $ui.DrvState.Foreground = $brush.Amber }
    elseif ($st.Running)   { $ui.DrvState.Text = '运行中'; $ui.DrvState.Foreground = $brush.Green }
    else                   { $ui.DrvState.Text = '已安装，未运行'; $ui.DrvState.Foreground = $brush.Amber }
    $ui.DrvVersion.Text = if ($st.Version) { "$($st.Version)$(if ($st.Date) { "（$($st.Date)）" })" } else { '—' }
    $ui.DrvInstance.Text = if ($st.InstanceId) { $st.InstanceId } else { '—' }
    $script:pkg = Find-DriverPackage
    if ($script:pkg) {
        $src = if ($script:pkg.Dir -like '*\WinGet\Packages\*') { 'winget 安装的 VDD Control' } else { $script:pkg.Dir }
        $ui.DrvPackage.Text = "$src$(if (-not $script:pkg.Devcon) { '（缺少 devcon.exe，无法安装）' })"
        $ui.DrvPackage.ToolTip = $script:pkg.Inf
    } else {
        $ui.DrvPackage.Text = '没找到。可以用 winget 安装 VDD Control，或点“选择…”指定驱动文件夹。'
        $ui.DrvPackage.ToolTip = $null
    }
    $ui.DrvConf.Text = "$SettingsFile$(if (-not (Test-Path $SettingsFile)) { '（不存在）' })"
    $ui.NavFooter.Text = "驱动 $(if ($st.Version) { $st.Version } else { '未安装' })"
    Update-DriverButtons
}
function Update-DriverButtons {
    $st = $script:drv
    $busy = [bool]$script:op
    $canInstall = $script:pkg -and $script:pkg.Devcon
    $ui.BtnDrvReload.IsEnabled    = -not $busy -and $st.Installed -and -not $st.Disabled
    $ui.BtnDrvDisable.IsEnabled   = -not $busy -and $st.Installed -and -not $st.Disabled
    $ui.BtnDrvEnable.IsEnabled    = -not $busy -and $st.Installed -and $st.Disabled
    $ui.BtnDrvInstall.IsEnabled   = -not $busy -and -not $st.Installed -and $canInstall
    $ui.BtnDrvReinstall.IsEnabled = -not $busy -and $st.Installed -and $canInstall
    $ui.BtnDrvUninstall.IsEnabled = -not $busy -and $st.Installed
}
function q([string]$s) { "'" + ($s -replace "'", "''") + "'" }
function Get-InstallBody {
    "& $(q $script:pkg.Devcon) install $(q $script:pkg.Inf) '$HwId'`r`n`$global:rc = if (`$LASTEXITCODE -le 1) { 0 } else { `$LASTEXITCODE }"
}
function Get-UninstallBody {
    if ($script:pkg -and $script:pkg.Devcon) {
        "& $(q $script:pkg.Devcon) remove '$HwId'`r`n`$global:rc = if (`$LASTEXITCODE -le 1) { 0 } else { `$LASTEXITCODE }"
    } else {
        "pnputil /remove-device '$($script:drv.InstanceId)'`r`n`$global:rc = if (`$LASTEXITCODE -in 0,3010) { 0 } else { `$LASTEXITCODE }"
    }
}
# 虚拟屏是唯一显示器时，停用它会让本地画面切到别的输出或黑屏
function Confirm-OnlyDisplay([string]$action) {
    $disps = [VddCn.Native]::GetDisplays()
    if ($disps.Count -gt 0 -and @($disps | Where-Object { -not $_.IsVirtual }).Count -eq 0) {
        return Ask "现在只有虚拟屏在用。$action 后画面会切换到其他输出，如果没有可用的显示器可能会黑屏（远程连接也可能断开）。`n`n确定继续吗？" '注意'
    }
    return $true
}

# ================= 配置文件 =================
function Load-RawPage {
    $ui.RawPath.Text = $SettingsFile
    $ui.RawText.Text = if (Test-Path $SettingsFile) { [IO.File]::ReadAllText($SettingsFile) } else { '' }
    $ui.CmbBackup.Items.Clear()
    foreach ($f in @(Get-ChildItem $BackupDir -Filter 'vdd_settings_*.xml' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $label = if ($f.Name -match '_(\d{8})_(\d{6})') {
            '{0}-{1}-{2} {3}:{4}:{5}' -f $Matches[1].Substring(0, 4), $Matches[1].Substring(4, 2), $Matches[1].Substring(6, 2),
                $Matches[2].Substring(0, 2), $Matches[2].Substring(2, 2), $Matches[2].Substring(4, 2)
        } else { $f.Name }
        [void]$ui.CmbBackup.Items.Add((New-Item-Combo $label $f.FullName))
    }
    if ($ui.CmbBackup.Items.Count) { $ui.CmbBackup.SelectedIndex = 0 }
    $ui.BtnRestore.IsEnabled = $ui.CmbBackup.Items.Count -gt 0
}
function Test-XmlText([string]$text) {
    try { (New-Object Xml.XmlDocument).LoadXml($text) }
    catch {
        $ex = $_.Exception.GetBaseException()
        $where = if ($ex -is [Xml.XmlException]) { "第 $($ex.LineNumber) 行，第 $($ex.LinePosition) 列：" } else { '' }
        throw "XML 格式有误，没有保存。`n$where$($ex.Message)"
    }
}
function Save-RawPage {
    $text = $ui.RawText.Text
    Test-XmlText $text
    Backup-Settings
    [IO.File]::WriteAllText($SettingsFile, $text, (New-Object Text.UTF8Encoding($false)))
    Set-Status '配置文件已保存。' 'Green'
    Load-RawPage
}

# ================= 导航 =================
$pages = 0..6 | ForEach-Object { $ui["Page$_"] }
function Show-Page([int]$i) {
    for ($k = 0; $k -lt $pages.Count; $k++) { $pages[$k].Visibility = if ($k -eq $i) { 'Visible' } else { 'Collapsed' } }
    switch ($i) {
        0 { Refresh-Overview }
        1 { Refresh-DisplayPage }
        2 { Refresh-AutoSwitch }
        3 { if (-not $script:resDirty) { Load-ResPage } }
        4 { Load-OptPage }
        5 { Refresh-Driver }
        6 { Load-RawPage }
    }
}
$ui.Nav.Add_SelectionChanged({ Safe { Show-Page $ui.Nav.SelectedIndex } })

# ================= 事件绑定 =================
$ui.OvRefresh.Add_Click({ Safe { $script:ovSig = ''; Refresh-Overview; Set-Status '已刷新。' } })
$ui.OvReload.Add_Click({ Safe { if (Ask '重启驱动会让所有虚拟屏断开几秒，确定吗？') { Invoke-DriverReload } } })
$ui.OvWinSettings.Add_Click({ Safe { Start-Process 'ms-settings:display' } })

$ui.CmbDisplay.Add_SelectionChanged({ Safe { if (-not $script:loading -and $ui.CmbDisplay.SelectedItem) { Load-Modes } } })
$ui.CmbRes.Add_SelectionChanged({ Safe { if (-not $script:loading) { Load-Rates } } })
$ui.BtnApplyMode.Add_Click({ Safe { Apply-Mode } })
$ui.BtnDispRefresh.Add_Click({ Safe { Refresh-DisplayPage; Set-Status '已刷新。' } })
$ui.BtnSetPrimary.Add_Click({ Safe {
    $dev = $ui.CmbDisplay.SelectedItem.Tag
    $r = [VddCn.Native]::SetPrimary($dev)
    if ($r -eq 0) { Set-Status "已把 $dev 设为主显示器。" 'Green' } else { Show-Error "设置主显示器失败（代码 $r）。" }
    Refresh-DisplayPage
} })
$ui.BtnApplyCount.Add_Click({ Safe {
    $n = $ui.CmbCount.SelectedItem.Tag
    $conf = Get-ConfiguredCount
    if ($n -eq $conf) { Set-Status "已经是 $n 块了。"; return }
    if (-not (Ask "把虚拟屏数量改为 $n 块？驱动会重新加载，所有虚拟屏会断开几秒。")) { return }
    if (Send-VddPipe "SETDISPLAYCOUNT $n") {
        Set-Status "已通知驱动改为 $n 块虚拟屏，几秒后生效。" 'Green'
    } else {
        $x = Get-Settings
        (Get-Node $x 'monitors/count').InnerText = [string]$n
        Save-Settings $x
        Invoke-DriverReload
    }
    $script:refreshIn = 5
} })

$ui.BtnAsEnable.Add_Click({ Safe {
    Enable-AutoSwitch
    Set-Status '自动切换已开启。' 'Green'
    $script:refreshIn = 3
    Refresh-AutoSwitch
} })
$ui.BtnAsDisable.Add_Click({ Safe {
    Disable-AutoSwitch
    Set-Status '自动切换已关闭，现在的显示布局保持不变。' 'Amber'
    Refresh-AutoSwitch
} })
$ui.BtnAsCheck.Add_Click({ Safe {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$(Join-Path $PSScriptRoot 'AutoSwitch.ps1')`"", '-Once')
    Set-Status '正在检查显示器，几秒后会更新记录。'
    $script:refreshIn = 4
} })

$ui.CmbPreset.Add_SelectionChanged({ Safe {
    $t = $ui.CmbPreset.SelectedItem.Tag
    if ($t) { $ui.TxtW.Text = $t[0]; $ui.TxtH.Text = $t[1] }
} })
$ui.BtnResAdd.Add_Click({ Safe {
    $w = Read-Int $ui.TxtW '宽度' 320 15360
    $h = Read-Int $ui.TxtH '高度' 200 8640
    $hz = Read-Int $ui.TxtHz '刷新率' 1 1000
    if (@($script:resRows | Where-Object { $_.Width -eq $w -and $_.Height -eq $h -and $_.Hz -eq $hz }).Count) { throw '列表里已经有这个分辨率了。' }
    $r = New-Object VddCn.ResRow
    $r.Width = $w; $r.Height = $h; $r.Hz = $hz
    $script:resRows.Add($r)
    $ui.ResGrid.ScrollIntoView($r)
    $script:resDirty = $true
    Set-Status "已添加 $w × $h @ ${hz}Hz（还没保存）。"
} })
$ui.BtnResDel.Add_Click({ Safe {
    $sel = @($ui.ResGrid.SelectedItems)
    if (-not $sel.Count) { Set-Status '请先在列表里选中要删除的分辨率。' 'Amber'; return }
    foreach ($r in $sel) { [void]$script:resRows.Remove($r) }
    $script:resDirty = $true
    Set-Status "已删除 $($sel.Count) 项（还没保存）。"
} })
$ui.ResGrid.Add_CellEditEnding({ $script:resDirty = $true })
$ui.BtnGlobalAdd.Add_Click({ Safe {
    $v = Read-Int $ui.TxtGlobal '刷新率' 1 1000
    if ($ui.GlobalList.Items -contains $v) { throw '已经有这个刷新率了。' }
    [void]$ui.GlobalList.Items.Add($v)
    $ui.TxtGlobal.Text = ''
    $script:resDirty = $true
} })
$ui.BtnGlobalDel.Add_Click({ Safe {
    foreach ($v in @($ui.GlobalList.SelectedItems)) { $ui.GlobalList.Items.Remove($v) }
    $script:resDirty = $true
} })
$ui.BtnResSave.Add_Click({ Safe { Save-ResPage } })
$ui.BtnResSaveReload.Add_Click({ Safe { Save-ResPage; Invoke-DriverReload } })
$ui.BtnResReload.Add_Click({ Safe { Load-ResPage; Set-Status '已重新读取。' } })

$ui.BtnOptSave.Add_Click({ Safe { Save-OptPage } })
$ui.BtnOptSaveReload.Add_Click({ Safe { Save-OptPage; Invoke-DriverReload } })
$ui.BtnOptReload.Add_Click({ Safe { Load-OptPage; Set-Status '已重新读取。' } })

$ui.BtnPickPkg.Add_Click({ Safe {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择包含 MttVDD.inf 的驱动文件夹（例如解压后的 VDD Control 或 Driver.Only 压缩包）'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    if (-not (Get-ChildItem $dlg.SelectedPath -Recurse -Depth 4 -Filter 'MttVDD.inf' -ErrorAction SilentlyContinue)) { throw '这个文件夹里没有找到 MttVDD.inf。' }
    $cfg = Get-AppConfig
    $cfg | Add-Member -NotePropertyName PackageDir -NotePropertyValue $dlg.SelectedPath -Force
    Save-AppConfig $cfg
    Refresh-Driver
} })
$ui.BtnDrvReload.Add_Click({ Safe { if (Ask '重启驱动会让所有虚拟屏断开几秒，确定吗？') { Invoke-DriverReload } } })
$ui.BtnDrvDisable.Add_Click({ Safe {
    if (-not (Confirm-OnlyDisplay '禁用驱动')) { return }
    if (-not (Ask '禁用后所有虚拟屏会消失，之后可以在这里重新启用。确定禁用吗？')) { return }
    Start-AdminOp '禁用驱动' "pnputil /disable-device '$($script:drv.InstanceId)'`r`n`$global:rc = if (`$LASTEXITCODE -in 0,3010) { 0 } else { `$LASTEXITCODE }"
} })
$ui.BtnDrvEnable.Add_Click({ Safe {
    Start-AdminOp '启用驱动' "pnputil /enable-device '$($script:drv.InstanceId)'`r`n`$global:rc = if (`$LASTEXITCODE -in 0,3010) { 0 } else { `$LASTEXITCODE }"
} })
$ui.BtnDrvInstall.Add_Click({ Safe { Start-AdminOp '安装驱动' (Get-InstallBody) } })
$ui.BtnDrvReinstall.Add_Click({ Safe {
    if (-not (Confirm-OnlyDisplay '重新安装驱动')) { return }
    if (-not (Ask '先卸载再安装，虚拟屏会消失十几秒。确定重新安装吗？')) { return }
    Start-AdminOp '重新安装驱动' "$(Get-UninstallBody)`r`nStart-Sleep -Seconds 3`r`n$(Get-InstallBody)"
} })
$ui.BtnDrvUninstall.Add_Click({ Safe {
    if (-not (Confirm-OnlyDisplay '卸载驱动')) { return }
    if (-not (Ask '卸载后虚拟屏会消失，配置文件会保留。确定卸载吗？')) { return }
    Start-AdminOp '卸载驱动' (Get-UninstallBody)
} })

$ui.BtnRawSave.Add_Click({ Safe { Save-RawPage } })
$ui.BtnRawSaveReload.Add_Click({ Safe { Save-RawPage; Invoke-DriverReload } })
$ui.BtnRawLoad.Add_Click({ Safe { Load-RawPage; Set-Status '已重新读取。' } })
$ui.BtnRawNotepad.Add_Click({ Safe { Start-Process notepad.exe -ArgumentList "`"$SettingsFile`"" } })
$ui.BtnRawFolder.Add_Click({ Safe { Start-Process explorer.exe -ArgumentList "/select,`"$SettingsFile`"" } })
$ui.BtnBackupFolder.Add_Click({ Safe { New-Item -ItemType Directory -Force $BackupDir | Out-Null; Start-Process explorer.exe -ArgumentList "`"$BackupDir`"" } })
$ui.BtnRestore.Add_Click({ Safe {
    $f = $ui.CmbBackup.SelectedItem.Tag
    if (-not (Ask "用 $($ui.CmbBackup.SelectedItem.Content) 的备份覆盖当前配置？当前配置会先备份。")) { return }
    Test-XmlText ([IO.File]::ReadAllText($f))
    Backup-Settings
    Copy-Item $f $SettingsFile -Force
    Load-RawPage
    $script:resDirty = $false
    if (Ask '已恢复。要现在重启驱动让它生效吗？') { Invoke-DriverReload }
} })

# ================= 定时刷新 =================
$script:tick = 0
$script:refreshIn = 0
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    try {
        $script:tick++
        if ($script:op -and $script:op.Proc.HasExited) { Complete-AdminOp }
        if ($script:refreshIn -gt 0) {
            $script:refreshIn--
            if ($script:refreshIn -eq 0) {
                Refresh-Driver
                switch ($ui.Nav.SelectedIndex) { 0 { Refresh-Overview } 1 { Refresh-DisplayPage } 2 { Refresh-AutoSwitch } }
            }
        }
        if ($script:tick % 3 -eq 0) {
            if ($ui.Nav.SelectedIndex -eq 0) { Refresh-Overview }
            if ($ui.Nav.SelectedIndex -eq 2) { Refresh-AutoSwitch }
            if ($ui.Nav.SelectedIndex -eq 5 -and -not $script:op) { Refresh-Driver }
        }
    } catch {}
})

$win.Dispatcher.Add_UnhandledException({ param($s, $e) $e.Handled = $true; Show-Error "$($e.Exception.Message)" })
$win.Add_Loaded({ Safe { Refresh-Driver; $ui.Nav.SelectedIndex = 0; $timer.Start() } })
$win.Add_Closed({ $timer.Stop() })

[void]$win.ShowDialog()
