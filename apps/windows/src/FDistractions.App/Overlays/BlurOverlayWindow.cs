using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using FDistractions.App.Capture;
using FDistractions.App.Interop;

namespace FDistractions.App.Overlays;

/// <summary>
/// Full-screen, click-through blur for one monitor. Windows has no reliable "blur whatever is behind
/// this window" effect for an inactive click-through window, so this prototype shows a blurred copy
/// of the screenshot that was assessed. Clicks still pass through to the apps underneath.
/// </summary>
internal sealed class BlurOverlayWindow : Window
{
    private static readonly TimeSpan RevealDuration = TimeSpan.FromSeconds(1.4);
    private const double StartingEdge = 10;

    private readonly DisplayInfo _display;
    private readonly Grid _surface;

    public BlurOverlayWindow(DisplayInfo display, BitmapSource snapshot)
    {
        _display = display;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        Title = "F Distractions blur";
        // Rough initial size in device-independent units; the real position is set in pixels below.
        Left = display.Bounds.Left / display.Scale;
        Top = display.Bounds.Top / display.Scale;
        Width = display.Bounds.Width / display.Scale;
        Height = display.Bounds.Height / display.Scale;

        var image = new Image
        {
            Source = snapshot,
            Stretch = Stretch.Fill,
            // Extend past the edges so the blur doesn't fade to transparent at the sides.
            Margin = new Thickness(-60),
            Effect = new BlurEffect { Radius = 48, KernelType = KernelType.Gaussian, RenderingBias = RenderingBias.Performance },
        };
        var wash = new System.Windows.Shapes.Rectangle { Fill = new SolidColorBrush(Color.FromArgb(0x59, 0xF2, 0xF2, 0xED)) };
        _surface = new Grid { ClipToBounds = true };
        _surface.Children.Add(image);
        _surface.Children.Add(wash);
        Content = _surface;

        SourceInitialized += (_, _) =>
        {
            WindowInterop.MakeOverlay(this, clickThrough: true);
            WindowInterop.ExcludeFromCapture(this);
            WindowInterop.PlaceTopmost(this, _display.Bounds);
        };
        // Moving onto a monitor with different scaling makes WPF resize the window; put it back.
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(() => WindowInterop.PlaceTopmost(this, _display.Bounds));
        Loaded += (_, _) => Reveal();
    }

    /// <summary>The blur grows inward from the screen edges over 1.4 seconds.</summary>
    private void Reveal()
    {
        var width = _surface.ActualWidth;
        var height = _surface.ActualHeight;
        if (width <= 0 || height <= 0) return;

        var outer = new RectangleGeometry(new Rect(0, 0, width, height));
        var hole = new RectangleGeometry(new Rect(StartingEdge, StartingEdge,
            Math.Max(0, width - 2 * StartingEdge), Math.Max(0, height - 2 * StartingEdge)));
        _surface.Clip = new CombinedGeometry(GeometryCombineMode.Exclude, outer, hole);

        var shrink = new RectAnimation(new Rect(width / 2, height / 2, 0, 0), new Duration(RevealDuration))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut },
        };
        shrink.Completed += (_, _) => _surface.Clip = null;
        hole.BeginAnimation(RectangleGeometry.RectProperty, shrink);
    }
}
