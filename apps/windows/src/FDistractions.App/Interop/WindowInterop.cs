using System;
using System.Drawing;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Animation;

namespace FDistractions.App.Interop;

internal static class WindowInterop
{
    /// <summary>Set if Windows refused to hide one of our windows from screen capture.</summary>
    public static bool CaptureExclusionFailed { get; private set; }

    public static IntPtr Handle(Window window) => new WindowInteropHelper(window).Handle;

    /// <summary>
    /// Overlay windows never take focus or appear in Alt-Tab. Click-through windows also let every
    /// mouse click fall to the app underneath.
    /// </summary>
    public static void MakeOverlay(Window window, bool clickThrough)
    {
        var hwnd = Handle(window);
        var style = NativeMethods.GetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        style |= NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW;
        if (clickThrough) style |= NativeMethods.WS_EX_TRANSPARENT | NativeMethods.WS_EX_LAYERED;
        NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(style));
    }

    /// <summary>
    /// Keeps blur/card overlay windows (including ones fading out) out of screenshots. The main
    /// window and dialogs are not excluded (docs/behaviour.md, "Assess all screens").
    /// </summary>
    public static void ExcludeFromCapture(Window window)
    {
        if (!NativeMethods.SetWindowDisplayAffinity(Handle(window), NativeMethods.WDA_EXCLUDEFROMCAPTURE))
            CaptureExclusionFailed = true;
    }

    /// <summary>Places a window in physical pixels, above normal windows, without activating it.</summary>
    public static void PlaceTopmost(Window window, Rectangle physical)
    {
        NativeMethods.SetWindowPos(Handle(window), NativeMethods.HWND_TOPMOST,
            physical.X, physical.Y, physical.Width, physical.Height, NativeMethods.SWP_NOACTIVATE);
    }

    public static void FadeOutAndClose(Window window, TimeSpan duration)
    {
        window.IsHitTestVisible = false;
        var fade = new DoubleAnimation(0, new Duration(duration));
        fade.Completed += (_, _) => window.Close();
        window.BeginAnimation(UIElement.OpacityProperty, fade);
    }
}
