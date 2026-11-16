using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using FDistractions.App.Interop;

namespace FDistractions.App.Capture;

/// <summary>A physical monitor. Bounds are in physical pixels (the app is per-monitor DPI aware).</summary>
/// <param name="Id">Windows device name, e.g. \\.\DISPLAY1.</param>
/// <param name="Scale">Windows display scaling, e.g. 1.25 for 125%.</param>
internal sealed record DisplayInfo(string Id, Rectangle Bounds, Rectangle WorkArea, bool IsPrimary, double Scale)
{
    public string Describe(int screenIndex)
    {
        var details = $"{Bounds.Width}×{Bounds.Height}";
        if (Math.Abs(Scale - 1) > 0.01) details += $" at {Scale * 100:0}%";
        if (IsPrimary) details += ", main display";
        return $"Screen {screenIndex} · {details}";
    }
}

internal static class Displays
{
    /// <summary>All connected monitors, ordered left-to-right then top-to-bottom like the Mac app.</summary>
    public static IReadOnlyList<DisplayInfo> Enumerate()
    {
        var found = new List<DisplayInfo>();
        NativeMethods.MonitorEnumProc callback = (IntPtr monitor, IntPtr hdc, ref NativeMethods.RECT rect, IntPtr data) =>
        {
            var info = new NativeMethods.MONITORINFOEX { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFOEX>(), szDevice = "" };
            if (NativeMethods.GetMonitorInfo(monitor, ref info))
            {
                var scale = NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out var dpiX, out _) == 0
                    ? dpiX / 96.0 : 1.0;
                found.Add(new DisplayInfo(info.szDevice, ToRectangle(info.rcMonitor), ToRectangle(info.rcWork),
                    (info.dwFlags & NativeMethods.MONITORINFOF_PRIMARY) != 0, scale));
            }
            return true;
        };
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return found
            .OrderBy(d => d.Bounds.Left)
            .ThenBy(d => d.Bounds.Top)
            .ThenBy(d => d.Id, StringComparer.Ordinal)
            .ToList();
    }

    private static Rectangle ToRectangle(NativeMethods.RECT r) => Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
}
