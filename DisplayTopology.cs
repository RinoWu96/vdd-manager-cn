// 显示拓扑（CCD API）：查询哪些显示器已连接 / 已启用，启用全部显示器，断开虚拟屏。
// VDDManager.ps1 和 AutoSwitch.ps1 都会加载这个文件。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace VddCn
{
    public class DisplayTarget
    {
        public uint AdapterLow { get; set; }
        public int AdapterHigh { get; set; }
        public uint Id { get; set; }
        public bool Available { get; set; }
        public bool Active { get; set; }
        public bool IsVdd { get; set; }
        public bool IsVirtual { get; set; }
        public bool IsInternal { get; set; }
        public string Name { get; set; }
        public string Path { get; set; }
        public string Gdi { get; set; }
        public string AvailableText { get { return Available ? "已连接" : "未连接"; } }
        public string ActiveText { get { return Active ? "✔ 已启用" + (string.IsNullOrEmpty(Gdi) ? "" : "（" + Gdi + "）") : "未启用"; } }
        public string Key { get { return AdapterHigh + ":" + AdapterLow + ":" + Id; } }
        public string Kind { get { return IsVdd ? "VDD 虚拟屏" : IsVirtual ? "其他虚拟屏" : IsInternal ? "内屏" : "外接屏"; } }
        public string Label { get { return string.IsNullOrEmpty(Name) ? Kind : Kind + "（" + Name + "）"; } }
    }

    public static class Topology
    {
        [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct RATIONAL { public uint N, D; }
        [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
        [StructLayout(LayoutKind.Sequential)]
        struct PATH_TARGET
        {
            public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology;
            public uint rotation; public uint scaling; public RATIONAL refreshRate; public uint scanLineOrdering;
            public int targetAvailable; public uint statusFlags;
        }
        [StructLayout(LayoutKind.Sequential)] struct PATH { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }
        [StructLayout(LayoutKind.Sequential)]
        struct MODE
        {
            public uint infoType; public uint id; public LUID adapterId;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)] public byte[] data;
        }
        [StructLayout(LayoutKind.Sequential)] struct HEADER { public uint type; public uint size; public LUID adapterId; public uint id; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct TARGET_NAME
        {
            public HEADER header; public uint flags; public uint outputTechnology;
            public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SOURCE_NAME { public HEADER header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName; }

        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH[] paths, ref uint numModes, [Out] MODE[] modes, IntPtr topologyId);
        [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPaths, [In] PATH[] paths, uint numModes, [In] MODE[] modes, uint flags);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME info);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SOURCE_NAME info);

        const uint QDC_ALL_PATHS = 0x1, QDC_ONLY_ACTIVE_PATHS = 0x2;
        const uint PATH_ACTIVE = 0x1;
        const uint MODE_SOURCE = 1;
        const uint INVALID_IDX = 0xFFFFFFFF;
        const uint SDC_TOPOLOGY_EXTEND = 0x4, SDC_APPLY = 0x80, SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x20;
        const uint SDC_SAVE_TO_DATABASE = 0x200, SDC_ALLOW_CHANGES = 0x400;
        const uint TECH_INTERNAL = 0x80000000, TECH_LVDS = 6, TECH_DP_EMBEDDED = 11, TECH_UDI_EMBEDDED = 13, TECH_INDIRECT_VIRTUAL = 17;

        // 设备路径里含这些标识的视为虚拟屏：VDD、TeamViewer、Parsec、IddSample 等
        static readonly string[] VirtualIds = { "MTT1337", "TMV0000", "PSCCDD", "IDD_HDR", "LNXVDD", "RDPUDD" };
        const string VddId = "MTT1337";

        static PATH[] Query(uint flags, out MODE[] modes)
        {
            uint np, nm;
            int err = GetDisplayConfigBufferSizes(flags, out np, out nm);
            if (err != 0) throw new InvalidOperationException("GetDisplayConfigBufferSizes 失败：" + err);
            var paths = new PATH[np];
            modes = new MODE[nm];
            err = QueryDisplayConfig(flags, ref np, paths, ref nm, modes, IntPtr.Zero);
            if (err != 0) throw new InvalidOperationException("QueryDisplayConfig 失败：" + err);
            Array.Resize(ref paths, (int)np);
            Array.Resize(ref modes, (int)nm);
            return paths;
        }

        static TARGET_NAME TargetName(PATH_TARGET t)
        {
            var n = new TARGET_NAME();
            n.header.type = 2;
            n.header.size = (uint)Marshal.SizeOf(typeof(TARGET_NAME));
            n.header.adapterId = t.adapterId;
            n.header.id = t.id;
            DisplayConfigGetDeviceInfo(ref n);
            return n;
        }

        static string SourceGdi(PATH_SOURCE s)
        {
            var n = new SOURCE_NAME();
            n.header.type = 1;
            n.header.size = (uint)Marshal.SizeOf(typeof(SOURCE_NAME));
            n.header.adapterId = s.adapterId;
            n.header.id = s.id;
            return DisplayConfigGetDeviceInfo(ref n) == 0 ? n.viewGdiDeviceName : null;
        }

        static bool Contains(string s, string sub) { return s != null && s.IndexOf(sub, StringComparison.OrdinalIgnoreCase) >= 0; }

        static bool IsVddPath(PATH p) { return Contains(TargetName(p.targetInfo).monitorDevicePath, VddId); }

        // 所有显示器（每个输出口一条），包括已连接但未启用的
        public static List<DisplayTarget> GetTargets()
        {
            MODE[] modes;
            var paths = Query(QDC_ALL_PATHS, out modes);
            var map = new Dictionary<string, DisplayTarget>();
            var list = new List<DisplayTarget>();
            foreach (var p in paths)
            {
                var t = p.targetInfo;
                string key = t.adapterId.High + ":" + t.adapterId.Low + ":" + t.id;
                DisplayTarget d;
                if (!map.TryGetValue(key, out d))
                {
                    var n = TargetName(t);
                    uint tech = t.outputTechnology;
                    bool isVirtual = tech == TECH_INDIRECT_VIRTUAL;
                    foreach (var id in VirtualIds) if (Contains(n.monitorDevicePath, id)) isVirtual = true;
                    d = new DisplayTarget {
                        AdapterLow = t.adapterId.Low, AdapterHigh = t.adapterId.High, Id = t.id,
                        Name = n.monitorFriendlyDeviceName, Path = n.monitorDevicePath,
                        IsVdd = Contains(n.monitorDevicePath, VddId), IsVirtual = isVirtual,
                        IsInternal = tech == TECH_INTERNAL || tech == TECH_LVDS || tech == TECH_DP_EMBEDDED || tech == TECH_UDI_EMBEDDED };
                    map[key] = d;
                    list.Add(d);
                }
                if (t.targetAvailable != 0) d.Available = true;
                if ((p.flags & PATH_ACTIVE) != 0) { d.Active = true; d.Gdi = SourceGdi(p.sourceInfo); }
            }
            // 只保留连着显示器的输出口
            return list.FindAll(x => x.Available || x.Active);
        }

        // 启用所有已连接的显示器（扩展模式），返回 0 表示成功
        public static int ExtendAll()
        {
            return SetDisplayConfig(0, null, 0, null, SDC_APPLY | SDC_TOPOLOGY_EXTEND | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
        }

        // 断开所有 VDD 虚拟屏，其余显示器保持不变；主显示器优先选内屏。返回 0 成功，1 表示本来就没有启用的虚拟屏
        public static int DetachVdd()
        {
            MODE[] modes;
            var paths = Query(QDC_ONLY_ACTIVE_PATHS, out modes);
            var keep = new List<PATH>();
            bool removed = false;
            foreach (var p in paths) { if (IsVddPath(p)) removed = true; else keep.Add(p); }
            if (!removed) return 1;
            if (keep.Count == 0) return -2;   // 没有别的显示器，不能断开

            // 只保留仍被引用的模式，并重新编号
            var newModes = new List<MODE>();
            var remap = new Dictionary<uint, uint>();
            Func<uint, uint> map = idx => {
                if (idx == INVALID_IDX || idx >= modes.Length) return idx;
                uint n;
                if (!remap.TryGetValue(idx, out n)) { n = (uint)newModes.Count; newModes.Add(modes[idx]); remap[idx] = n; }
                return n;
            };
            var arr = keep.ToArray();
            for (int i = 0; i < arr.Length; i++)
            {
                arr[i].sourceInfo.modeInfoIdx = map(arr[i].sourceInfo.modeInfoIdx);
                arr[i].targetInfo.modeInfoIdx = map(arr[i].targetInfo.modeInfoIdx);
            }
            var modeArr = newModes.ToArray();

            // 选新的主显示器：内屏优先，否则第一个；把它平移到 (0,0)
            int primary = 0;
            for (int i = 0; i < arr.Length; i++)
            {
                uint tech = arr[i].targetInfo.outputTechnology;
                if (tech == TECH_INTERNAL || tech == TECH_LVDS || tech == TECH_DP_EMBEDDED || tech == TECH_UDI_EMBEDDED) { primary = i; break; }
            }
            uint pIdx = arr[primary].sourceInfo.modeInfoIdx;
            if (pIdx != INVALID_IDX && pIdx < modeArr.Length && modeArr[pIdx].infoType == MODE_SOURCE)
            {
                int ox = BitConverter.ToInt32(modeArr[pIdx].data, 12), oy = BitConverter.ToInt32(modeArr[pIdx].data, 16);
                for (int m = 0; m < modeArr.Length; m++)
                {
                    if (modeArr[m].infoType != MODE_SOURCE) continue;
                    int x = BitConverter.ToInt32(modeArr[m].data, 12) - ox, y = BitConverter.ToInt32(modeArr[m].data, 16) - oy;
                    Array.Copy(BitConverter.GetBytes(x), 0, modeArr[m].data, 12, 4);
                    Array.Copy(BitConverter.GetBytes(y), 0, modeArr[m].data, 16, 4);
                }
            }
            return SetDisplayConfig((uint)arr.Length, arr, (uint)modeArr.Length, modeArr,
                SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
        }
    }
}
