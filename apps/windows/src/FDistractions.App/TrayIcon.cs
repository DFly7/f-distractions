using System;
using System.Drawing;
using FDistractions.App.Interop;
using WinForms = System.Windows.Forms;

namespace FDistractions.App;

/// <summary>The notification-area (system tray) icon. Closing the main window keeps the app running here.</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly WinForms.NotifyIcon _icon;
    private readonly Icon _image;

    public event Action? OpenRequested;
    public event Action? QuitRequested;

    public TrayIcon()
    {
        _image = LoadIcon();
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open F Distractions", null, (_, _) => OpenRequested?.Invoke());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => QuitRequested?.Invoke());
        _icon = new WinForms.NotifyIcon
        {
            Icon = _image,
            Text = "F Distractions",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) => { if (e.Button == WinForms.MouseButtons.Left) OpenRequested?.Invoke(); };
    }

    public void SetTooltip(string text) => _icon.Text = text.Length > 63 ? text[..63] : text;

    public void ShowBalloon(string title, string text) => _icon.ShowBalloonTip(4000, title, text, WinForms.ToolTipIcon.None);

    private static Icon LoadIcon()
    {
        var resource = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/icon.png"));
        using var source = new Bitmap(resource!.Stream);
        using var small = new Bitmap(source, 32, 32);
        var handle = small.GetHicon();
        try { return (Icon)Icon.FromHandle(handle).Clone(); }
        finally { NativeMethods.DestroyIcon(handle); }
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _image.Dispose();
    }
}
