// VDDManager.exe：启动同目录下的 VDDManager.ps1，不显示控制台窗口。
// 由 build.ps1 用 .NET Framework 自带的 csc.exe 编译，不需要安装任何开发工具。
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("虚拟显示器管理器")]
[assembly: AssemblyDescription("Virtual Display Driver 中文管理器")]
[assembly: AssemblyProduct("VDD 中文管理器")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

static class Program
{
    const string Title = "虚拟显示器管理器";

    // 无参数：打开管理器窗口（启动后立即退出）
    // --autoswitch：运行后台自动切换（等它结束，供计划任务判断是否还在运行）
    [STAThread]
    static int Main(string[] args)
    {
        bool autoSwitch = args.Length > 0 && args[0].Equals("--autoswitch", StringComparison.OrdinalIgnoreCase);
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, autoSwitch ? "AutoSwitch.ps1" : "VDDManager.ps1");
        if (!File.Exists(script))
        {
            if (!autoSwitch)
                MessageBox.Show("找不到 " + Path.GetFileName(script) + "。\n请把它和 VDDManager.exe 放在同一个文件夹里。",
                                Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                         @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(powershell,
            "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        try
        {
            var p = Process.Start(psi);
            if (!autoSwitch) return 0;
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception e)
        {
            if (!autoSwitch)
                MessageBox.Show("无法启动 PowerShell：\n" + e.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }
}
