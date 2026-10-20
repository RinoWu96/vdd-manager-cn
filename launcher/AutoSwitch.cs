// 自动切换虚拟屏（运行在 VDDManager.exe --autoswitch 里，不需要 PowerShell）：
//   - 有实体显示器（笔记本内屏或外接屏）接入时，启用实体屏并断开 VDD 虚拟屏；
//   - 实体显示器都不可用时（例如合盖远程），接回 VDD 虚拟屏。
// 只在实体显示器接入 / 拔出的那一刻动作，之后手动调整的布局不会被覆盖。
// 由显示器插拔、显示设置变化、合盖 / 开盖、睡眠唤醒等系统通知触发，另每 30 秒兜底检查一次。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace VddCn
{
    static class AutoSwitch
    {
        static readonly string AppDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VDDManagerCN");
        static readonly string LogFile = Path.Combine(AppDir, "autoswitch.log");
        static readonly string PidFile = Path.Combine(AppDir, "autoswitch.pid");

        static string lastKey;                       // 上次看到的实体显示器集合
        static System.Windows.Forms.Timer debounce;  // 事件后延迟检查
        static System.Windows.Forms.Timer poll;      // 兜底定时检查
        static int recheckLeft;

        class State
        {
            public List<DisplayTarget> Physical, PhysicalActive, Vdd, VddActive;
            public string Key;
        }

        static State GetState()
        {
            var all = Topology.GetTargets();
            var s = new State();
            s.Physical = all.Where(t => !t.IsVirtual && t.Available).ToList();
            s.PhysicalActive = s.Physical.Where(t => t.Active).ToList();
            s.Vdd = all.Where(t => t.IsVdd).ToList();
            s.VddActive = s.Vdd.Where(t => t.Active).ToList();
            s.Key = string.Join(",", s.Physical.Select(t => t.Key).OrderBy(k => k).ToArray());
            return s;
        }

        static string Describe(State s)
        {
            string p = s.Physical.Count == 0 ? "无"
                : string.Join("，", s.Physical.Select(t => t.Label + (t.Active ? "·已启用" : "·未启用")).ToArray());
            string v = s.Vdd.Count == 0 ? "未检测到" : s.VddActive.Count > 0 ? "已启用" : "已断开";
            return "实体显示器：" + p + "；虚拟屏：" + v;
        }

        static void Log(string msg)
        {
            try
            {
                Directory.CreateDirectory(AppDir);
                File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + "\r\n", new UTF8Encoding(false));
                if (new FileInfo(LogFile).Length > 256 * 1024)
                {
                    var lines = File.ReadAllLines(LogFile, Encoding.UTF8);
                    File.WriteAllLines(LogFile, lines.Skip(Math.Max(0, lines.Length - 500)).ToArray(), new UTF8Encoding(false));
                }
            }
            catch { }
        }

        // 切到实体屏：先把所有已连接的显示器都启用，再断开虚拟屏
        static void ToPhysical(State s)
        {
            if (s.PhysicalActive.Count == 0)
            {
                Log("启用所有已连接的显示器，结果 " + Topology.ExtendAll());
                Thread.Sleep(1500);
                s = GetState();
            }
            if (s.VddActive.Count > 0 && s.PhysicalActive.Count > 0)
                Log("断开虚拟屏，结果 " + Topology.DetachVdd());
        }

        // 接回虚拟屏：只剩虚拟屏可用时，“扩展”就等于启用它
        static void ToVirtual(State s)
        {
            if (s.Vdd.Count > 0 && s.VddActive.Count == 0)
                Log("实体显示器都不可用，接回虚拟屏，结果 " + Topology.ExtendAll());
        }

        static void Check(bool force)
        {
            try
            {
                var s = GetState();
                bool changed = s.Key != lastKey;
                if (changed || force)
                {
                    if (changed && lastKey != null) Log("显示器变化：" + Describe(s));
                    if (s.Physical.Count > 0) ToPhysical(s); else ToVirtual(s);
                    lastKey = s.Key;
                }
                else if (s.Physical.Count == 0 && s.Vdd.Count > 0 && s.VddActive.Count == 0)
                {
                    // 兜底：没有实体屏时虚拟屏被断开了（比如远程时误操作），立刻接回，避免完全没有画面
                    ToVirtual(s);
                }
            }
            catch (Exception e) { Log("出错：" + e.Message); }
        }

        // 系统通知：1.5 秒后检查，之后每 4 秒再补查两次（硬件就绪可能有延迟）
        public static void OnSystemEvent()
        {
            if (debounce == null) return;
            recheckLeft = 2;
            debounce.Stop();
            debounce.Interval = 1500;
            debounce.Start();
        }

        public static int RunOnce()
        {
            Log("手动检查：" + Describe(GetState()));
            Check(true);
            return 0;
        }

        public static int Run()
        {
            var mutex = new Mutex(false, @"Local\VDDManagerCN_AutoSwitch");
            try { if (!mutex.WaitOne(0)) return 0; }
            catch (AbandonedMutexException) { }
            try { Directory.CreateDirectory(AppDir); File.WriteAllText(PidFile, Process.GetCurrentProcess().Id.ToString()); } catch { }

            var window = new EventWindow();
            debounce = new System.Windows.Forms.Timer();
            debounce.Tick += (o, e) => {
                debounce.Stop();
                Check(false);
                if (recheckLeft-- > 0) { debounce.Interval = 4000; debounce.Start(); }
            };
            poll = new System.Windows.Forms.Timer { Interval = 30000 };
            poll.Tick += (o, e) => Check(false);
            poll.Start();

            Log("自动切换已启动（监听显示器变化，另每 30 秒兜底检查）。" + Describe(GetState()));
            Check(true);
            Application.Run();
            GC.KeepAlive(window);
            GC.KeepAlive(mutex);
            return 0;
        }
    }

    // 隐藏的顶层窗口，用来接收系统广播的显示 / 设备 / 电源 / 会话通知
    class EventWindow : NativeWindow
    {
        const int WM_DISPLAYCHANGE = 0x007E, WM_DEVICECHANGE = 0x0219, WM_POWERBROADCAST = 0x0218, WM_WTSSESSION_CHANGE = 0x02B1;
        const int DBT_DEVNODES_CHANGED = 0x0007, DBT_DEVICEARRIVAL = 0x8000, DBT_DEVICEREMOVECOMPLETE = 0x8004;
        const int PBT_APMRESUMEAUTOMATIC = 0x0012, PBT_POWERSETTINGCHANGE = 0x8013;
        static Guid MonitorInterface = new Guid("E6F07B5F-EE97-4A90-B076-33F57BF4EAA7");   // GUID_DEVINTERFACE_MONITOR
        static Guid LidSwitch = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");          // GUID_LIDSWITCH_STATE_CHANGE

        [StructLayout(LayoutKind.Sequential)]
        struct DEV_BROADCAST_DEVICEINTERFACE { public int dbcc_size; public int dbcc_devicetype; public int dbcc_reserved; public Guid dbcc_classguid; public short dbcc_name; }

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr RegisterDeviceNotification(IntPtr hRecipient, ref DEV_BROADCAST_DEVICEINTERFACE filter, int flags);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid powerSetting, int flags);
        [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSRegisterSessionNotification(IntPtr hWnd, int flags);

        public EventWindow()
        {
            CreateHandle(new CreateParams { Caption = "VDDManagerCN_AutoSwitch" });
            var f = new DEV_BROADCAST_DEVICEINTERFACE();
            f.dbcc_size = Marshal.SizeOf(typeof(DEV_BROADCAST_DEVICEINTERFACE));
            f.dbcc_devicetype = 5;   // DBT_DEVTYP_DEVICEINTERFACE
            f.dbcc_classguid = MonitorInterface;
            RegisterDeviceNotification(Handle, ref f, 0);
            RegisterPowerSettingNotification(Handle, ref LidSwitch, 0);
            WTSRegisterSessionNotification(Handle, 0);
        }

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_DISPLAYCHANGE:
                case WM_WTSSESSION_CHANGE:
                    AutoSwitch.OnSystemEvent();
                    break;
                case WM_DEVICECHANGE:
                    int d = m.WParam.ToInt32();
                    if (d == DBT_DEVICEARRIVAL || d == DBT_DEVICEREMOVECOMPLETE || d == DBT_DEVNODES_CHANGED) AutoSwitch.OnSystemEvent();
                    break;
                case WM_POWERBROADCAST:
                    int p = m.WParam.ToInt32();
                    if (p == PBT_APMRESUMEAUTOMATIC || p == PBT_POWERSETTINGCHANGE) AutoSwitch.OnSystemEvent();
                    m.Result = (IntPtr)1;
                    break;
            }
            base.WndProc(ref m);
        }
    }
}
