using System;
using System.Drawing;
using System.Windows;
using System.Windows.Media.Animation;
using FDistractions.App.Capture;
using FDistractions.App.Interop;
using FDistractions.Core;

namespace FDistractions.App.Overlays;

/// <summary>
/// The interactive card shown on top of one monitor's blur. It is clickable but never takes focus
/// from the app you were using, and Escape does nothing: only an explicit button dismisses it.
/// </summary>
internal partial class CardWindow : Window
{
    private const double CardWidth = 600;
    private const double CardHeight = 400;
    private readonly DisplayInfo _display;

    public event Action? ReturnClicked;

    public CardWindow(DisplayInfo display, string goal, Intervention intervention)
    {
        _display = display;
        InitializeComponent();
        GoalText.Text = goal;
        SetIntervention(intervention);

        SourceInitialized += (_, _) =>
        {
            WindowInterop.MakeOverlay(this, clickThrough: false);
            WindowInterop.ExcludeFromCapture(this);
            WindowInterop.PlaceTopmost(this, PhysicalFrame());
        };
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(() => WindowInterop.PlaceTopmost(this, PhysicalFrame()));
        Loaded += (_, _) => BeginAnimation(OpacityProperty, new DoubleAnimation(1, new Duration(TimeSpan.FromSeconds(0.4))));
    }

    public void SetIntervention(Intervention intervention)
    {
        ScreenLabel.Text = $"SCREEN {intervention.ScreenIndex}";
        ReasonText.Text = intervention.Reason;
    }

    private void OnReturnClick(object sender, RoutedEventArgs e)
    {
        ReturnButton.IsEnabled = false;
        ReturnClicked?.Invoke();
    }

    /// <summary>Centred in the monitor's work area, in physical pixels.</summary>
    private Rectangle PhysicalFrame()
    {
        var work = _display.WorkArea;
        var scale = _display.Scale;
        var width = (int)Math.Min(CardWidth * scale, work.Width - 40 * scale);
        var height = (int)Math.Min(CardHeight * scale, work.Height - 40 * scale);
        return new Rectangle(work.Left + (work.Width - width) / 2, work.Top + (work.Height - height) / 2, width, height);
    }
}
