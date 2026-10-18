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
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    const string Title = "虚拟显示器管理器";

    [STAThread]
    static int Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "VDDManager.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("找不到 VDDManager.ps1。\n请把它和 VDDManager.exe 放在同一个文件夹里。",
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
            Process.Start(psi);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("无法启动 PowerShell：\n" + e.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }
}
