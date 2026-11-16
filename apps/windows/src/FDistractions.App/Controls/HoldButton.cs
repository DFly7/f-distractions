using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using FDistractions.Core;

namespace FDistractions.App.Controls;

/// <summary>
/// "Hold for 10 seconds" control for early exit. Hold the mouse button, or Space while it has
/// keyboard focus. Releasing, dragging outside, losing focus or switching to another window resets
/// it. The session keeps running while you hold.
/// </summary>
internal sealed class HoldButton : Border
{
    public static readonly DependencyProperty VerbProperty = DependencyProperty.Register(
        nameof(Verb), typeof(string), typeof(HoldButton),
        new PropertyMetadata("continue", (d, _) => ((HoldButton)d).Redraw()));

    private readonly ContinuousHold _hold = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(30) };
    private readonly Border _progress;
    private readonly TextBlock _label;
    private Window? _window;

    public event Action? Completed;

    public string Verb
    {
        get => (string)GetValue(VerbProperty);
        set => SetValue(VerbProperty, value);
    }

    public HoldButton()
    {
        Height = 46;
        CornerRadius = new CornerRadius(9);
        Background = new SolidColorBrush(Color.FromRgb(0x1A, 0x1A, 0x1A));
        BorderThickness = new Thickness(2);
        BorderBrush = Brushes.Transparent;
        Focusable = true;
        Cursor = Cursors.Hand;
        ClipToBounds = true;

        _progress = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 0,
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(Color.FromRgb(0x4A, 0x5E, 0x33)),
        };
        _label = new TextBlock
        {
            Foreground = Brushes.White,
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var grid = new Grid();
        grid.Children.Add(_progress);
        grid.Children.Add(_label);
        Child = grid;

        _timer.Tick += (_, _) => Advance();
        Loaded += (_, _) =>
        {
            _window = Window.GetWindow(this);
            if (_window is not null) _window.Deactivated += OnWindowDeactivated;
            Redraw();
        };
        Unloaded += (_, _) =>
        {
            if (_window is not null) _window.Deactivated -= OnWindowDeactivated;
            ResetHold();
        };
        IsVisibleChanged += (_, _) => { if (!IsVisible) ResetHold(); };
        GotKeyboardFocus += (_, _) => BorderBrush = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF));
        LostKeyboardFocus += (_, _) => { BorderBrush = Brushes.Transparent; ResetHold(); };
        AutomationProperties_SetName();
    }

    private void AutomationProperties_SetName() =>
        System.Windows.Automation.AutomationProperties.SetHelpText(this,
            "Hold for ten seconds using the mouse button or Space. Releasing resets.");

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        Focus();
        CaptureMouse();
        BeginHold();
        e.Handled = true;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        ReleaseMouseCapture();
        ResetHold();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!_hold.IsHolding || e.LeftButton != MouseButtonState.Pressed) return;
        var position = e.GetPosition(this);
        if (position.X < 0 || position.Y < 0 || position.X > ActualWidth || position.Y > ActualHeight) ResetHold();
    }

    protected override void OnLostMouseCapture(MouseEventArgs e) => ResetHold();

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key != Key.Space) return;
        if (!e.IsRepeat) BeginHold();
        e.Handled = true;
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        if (e.Key != Key.Space) return;
        ResetHold();
        e.Handled = true;
    }

    private void OnWindowDeactivated(object? sender, EventArgs e) => ResetHold();

    private void BeginHold()
    {
        if (_window?.IsActive != true || !IsEnabled) return;
        _hold.Begin(_clock.Elapsed);
        _timer.Start();
        Redraw();
    }

    private void Advance()
    {
        if (_window?.IsActive != true) { ResetHold(); return; }
        if (_hold.Complete(_clock.Elapsed))
        {
            ResetHold();
            Completed?.Invoke();
        }
        else Redraw();
    }

    private void ResetHold()
    {
        _timer.Stop();
        _hold.Reset();
        if (IsMouseCaptured) ReleaseMouseCapture();
        Redraw();
    }

    private void Redraw()
    {
        var now = _clock.Elapsed;
        _progress.Width = Math.Max(0, ActualWidth - 4) * _hold.Progress(now);
        _label.Text = _hold.IsHolding
            ? $"Keep holding · {_hold.SecondsRemaining(now)}s"
            : $"Hold to {Verb} · 10s";
    }
}
