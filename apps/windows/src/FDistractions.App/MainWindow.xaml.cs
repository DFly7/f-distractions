using System;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using FDistractions.App.Capture;
using FDistractions.App.Interop;
using FDistractions.App.Session;
using FDistractions.Core;

namespace FDistractions.App;

public partial class MainWindow : Window
{
    private readonly SessionController _session;
    private CompletedCheck? _renderedCheck;
    private bool _allowClose;

    /// <summary>Raised when closing the window only hides it (the app keeps running in the tray).</summary>
    public event Action? HiddenToTray;

    internal MainWindow(SessionController session)
    {
        _session = session;
        InitializeComponent();

        foreach (var gap in MonitoringPolicy.AllowedGapSeconds) GapBox.Items.Add(new ComboBoxItem { Content = $"{gap} seconds", Tag = gap });
        GapBox.SelectedIndex = MonitoringPolicy.AllowedGapSeconds.ToList().IndexOf(MonitoringPolicy.DefaultGapSeconds);

        ProviderBox.Items.Add(new ComboBoxItem { Content = "Claude (your Claude Code sign-in)", Tag = Provider.ClaudeCode });
        ProviderBox.Items.Add(new ComboBoxItem { Content = "Test classifier (no AI, for testing)", Tag = Provider.Test });
        ProviderBox.SelectedIndex = 0;

        // Aliases are resolved by Claude Code itself; "default" leaves the choice to your Claude Code settings.
        foreach (var (label, alias) in new (string, string?)[]
                 { ("Claude Code default", null), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku") })
            ModelBox.Items.Add(new ComboBoxItem { Content = label, Tag = alias });
        ModelBox.SelectedIndex = 0;

        AddMode("Off task on the chosen screen, once (then on task)", FakeMode.OffTaskOnceOnScreen);
        AddMode("Off task on the chosen screen, every check", FakeMode.AlwaysOffTaskOnScreen);
        AddMode("Always on task", FakeMode.AlwaysOnTask);
        AddMode("Every check fails (error handling)", FakeMode.AlwaysFails);
        ClassifierBox.SelectedIndex = 0;

        PauseHold.Completed += () => _session.Pause("Paused. The timer is frozen and nothing is being captured.");
        EndHold.Completed += () => _session.End("Session ended early.");
        _session.Changed += Render;

        // The main window is deliberately captured like any other app window (docs/behaviour.md);
        // only the blur and card overlays are hidden from screenshots.
        Activated += (_, _) => Render();
        Loaded += async (_, _) => await RefreshClaudeStatusAsync();
        Render();
    }

    private enum Provider { ClaudeCode, Test }

    private ClaudeCodeStatus? _claudeStatus;

    private void AddMode(string label, FakeMode mode) => ClassifierBox.Items.Add(new ComboBoxItem { Content = label, Tag = mode });

    private FakeMode SelectedMode => (FakeMode)((ComboBoxItem)ClassifierBox.SelectedItem).Tag;

    private Provider SelectedProvider => (Provider)((ComboBoxItem)ProviderBox.SelectedItem).Tag;

    private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        var claude = SelectedProvider == Provider.ClaudeCode;
        ClaudePanel.Visibility = claude ? Visibility.Visible : Visibility.Collapsed;
        TestPanel.Visibility = claude ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void OnCheckClaudeClick(object sender, RoutedEventArgs e) => await RefreshClaudeStatusAsync();

    private async System.Threading.Tasks.Task RefreshClaudeStatusAsync()
    {
        ClaudeStatusText.Text = "Checking Claude Code…";
        ClaudeStatusText.Foreground = (System.Windows.Media.Brush)FindResource("MutedBrush");
        _claudeStatus = await ClaudeCodeSetup.CheckAsync(new SystemProcessRunner(), ClaudeCodeSetup.WorkingDirectory,
            System.Threading.CancellationToken.None);
        ClaudeStatusText.Text = _claudeStatus.Message;
        ClaudeStatusText.Foreground = (System.Windows.Media.Brush)FindResource(_claudeStatus.Ready ? "AccentBrush" : "ErrorBrush");
    }

    private IScreenClassifier CreateClassifier()
    {
        if (SelectedProvider == Provider.Test)
        {
            var target = TargetScreenBox.SelectedItem is ComboBoxItem { Tag: int screen } ? screen : 1;
            return new FakeClassifier(SelectedMode, target);
        }
        if (_claudeStatus is not { Ready: true, Executable: { } executable })
            throw new ArgumentException(_claudeStatus?.Message ?? "Still checking Claude Code. Try again in a moment.");
        var model = ((ComboBoxItem)ModelBox.SelectedItem).Tag as string;
        return new ClaudeCodeClassifier(executable, model, new SystemProcessRunner(), ClaudeCodeSetup.WorkingDirectory);
    }

    public void AllowClose() => _allowClose = true;

    public void ShowQuitHint() => QuitHint.Visibility = Visibility.Visible;

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            Hide();
            HiddenToTray?.Invoke();
        }
        base.OnClosing(e);
    }

    private void OnStartClick(object sender, RoutedEventArgs e)
    {
        SetupError.Visibility = Visibility.Collapsed;
        try
        {
            if (!int.TryParse(MinutesBox.Text.Trim(), out var minutes))
                throw new ArgumentException("Session length must be a whole number of minutes.");
            var gap = (int)((ComboBoxItem)GapBox.SelectedItem).Tag;
            _session.Start(GoalBox.Text, minutes, gap, CreateClassifier());
            QuitHint.Visibility = Visibility.Collapsed;
        }
        catch (ArgumentException error)
        {
            SetupError.Text = error.Message;
            SetupError.Visibility = Visibility.Visible;
        }
    }

    private void OnCheckNowClick(object sender, RoutedEventArgs e) => _session.CheckNow();

    private void OnResumeClick(object sender, RoutedEventArgs e) => _session.Resume();

    private void OnClassifierChanged(object sender, SelectionChangedEventArgs e)
    {
        var needsTarget = SelectedMode is FakeMode.OffTaskOnceOnScreen or FakeMode.AlwaysOffTaskOnScreen;
        TargetLabel.Visibility = TargetScreenBox.Visibility = needsTarget ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Render()
    {
        var displays = Displays.Enumerate();
        DisplaysText.Text = string.Join(Environment.NewLine, displays.Select((d, i) => d.Describe(i + 1)));
        CaptureWarning.Visibility = WindowInterop.CaptureExclusionFailed ? Visibility.Visible : Visibility.Collapsed;
        RenderTargetScreens(displays.Count);

        NoticeText.Text = _session.Notice ?? "";
        NoticeText.Visibility = string.IsNullOrEmpty(_session.Notice) ? Visibility.Collapsed : Visibility.Visible;

        var idle = _session.Phase == SessionPhase.Idle;
        SetupPanel.Visibility = idle ? Visibility.Visible : Visibility.Collapsed;
        RunningPanel.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        if (idle) return;

        var paused = _session.Phase == SessionPhase.Paused;
        RunningGoal.Text = _session.Goal;
        TimeText.Text = _session.Remaining.ToString(_session.Remaining.TotalHours >= 1 ? @"h\:mm\:ss" : @"mm\:ss");
        StateText.Text = paused
            ? "Paused. Resume when you're ready."
            : $"Focusing · {BlurredText()} · {NextCheckText()}";

        CheckingText.Visibility = _session.IsChecking ? Visibility.Visible : Visibility.Hidden;
        CheckNowButton.IsEnabled = !paused && !_session.IsChecking;
        CheckNowButton.Visibility = paused ? Visibility.Collapsed : Visibility.Visible;
        ResumeButton.Visibility = paused ? Visibility.Visible : Visibility.Collapsed;
        PauseHold.Visibility = paused ? Visibility.Collapsed : Visibility.Visible;

        ErrorText.Text = _session.LastError ?? "";
        ErrorText.Visibility = _session.LastError is null ? Visibility.Collapsed : Visibility.Visible;

        // Keep the previous completed result on screen while a new check runs.
        var check = _session.LastCheck;
        if (!ReferenceEquals(check, _renderedCheck))
        {
            _renderedCheck = check;
            ResultsList.Children.Clear();
            foreach (var screen in check?.Screens ?? [])
            {
                ResultsList.Children.Add(new TextBlock
                {
                    Margin = new Thickness(0, 4, 0, 0),
                    TextWrapping = TextWrapping.Wrap,
                    FontSize = 12,
                    Text = $"{screen.Label}: {screen.Status.Replace('_', ' ')}. {screen.Reason}",
                });
            }
        }
        LastCheckText.Text = check is null
            ? "No completed check yet."
            : $"Captured at {check.CapturedAt.LocalDateTime:HH:mm:ss} · {check.Classifier}";
    }

    private string BlurredText() => _session.BlurredScreens switch
    {
        0 => "no screens blurred",
        1 => "1 screen blurred",
        var n => $"{n} screens blurred",
    };

    private string NextCheckText()
    {
        if (_session.IsChecking) return "checking now";
        if (_session.NextCheckAt is not { } next) return "no check scheduled";
        var seconds = Math.Max(0, (int)Math.Ceiling((next - DateTimeOffset.Now).TotalSeconds));
        return $"next check in {seconds}s";
    }

    private void RenderTargetScreens(int count)
    {
        if (TargetScreenBox.Items.Count == count) return;
        var previous = TargetScreenBox.SelectedIndex;
        TargetScreenBox.Items.Clear();
        for (var i = 1; i <= count; i++) TargetScreenBox.Items.Add(new ComboBoxItem { Content = $"Screen {i}", Tag = i });
        TargetScreenBox.SelectedIndex = previous >= 0 && previous < count ? previous : count - 1;
    }
}
