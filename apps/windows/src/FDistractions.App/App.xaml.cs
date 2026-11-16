using System.Windows;
using FDistractions.App.Session;

namespace FDistractions.App;

public partial class App : Application
{
    private SessionController? _session;
    private TrayIcon? _tray;
    private MainWindow? _main;
    private bool _toldAboutTray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _session = new SessionController();
        _main = new MainWindow(_session);
        _tray = new TrayIcon();
        _tray.OpenRequested += ShowMain;
        _tray.QuitRequested += Quit;
        _main.HiddenToTray += () =>
        {
            if (_toldAboutTray) return;
            _toldAboutTray = true;
            _tray.ShowBalloon("F Distractions is still running", "Open it again from the tray icon.");
        };
        _session.Changed += () => _tray.SetTooltip(_session.Phase switch
        {
            SessionPhase.Running => $"F Distractions · focusing · {_session.Remaining:h\\:mm\\:ss} left",
            SessionPhase.Paused => "F Distractions · paused",
            _ => "F Distractions",
        });
        _main.Show();
    }

    private void ShowMain()
    {
        if (_main is null) return;
        _main.Show();
        if (_main.WindowState == WindowState.Minimized) _main.WindowState = WindowState.Normal;
        _main.Activate();
    }

    /// <summary>Quitting during a session goes through the same ten-second End hold.</summary>
    private void Quit()
    {
        if (_session is null || _main is null || _tray is null) return;
        if (_session.Phase != SessionPhase.Idle)
        {
            ShowMain();
            _main.ShowQuitHint();
            return;
        }
        _main.AllowClose();
        _main.Close();
        _session.Dispose();
        _tray.Dispose();
        Shutdown();
    }
}
