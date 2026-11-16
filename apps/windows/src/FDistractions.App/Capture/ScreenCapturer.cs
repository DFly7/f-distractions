using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Media.Imaging;
using FDistractions.Core;

namespace FDistractions.App.Capture;

internal sealed record CapturedScreen(DisplayInfo Display, ScreenImage Image, BitmapSource Preview);

internal sealed record CaptureSet(IReadOnlyList<CapturedScreen> Screens, DateTimeOffset CapturedAt);

/// <summary>
/// Captures every connected monitor. Screenshots stay in memory: nothing is written to disk.
/// The blur/card overlays are hidden from capture with SetWindowDisplayAffinity (see WindowInterop);
/// the main window is captured like any other window.
/// If any monitor fails, the whole check fails rather than assessing a partial set.
/// </summary>
internal static class ScreenCapturer
{
    private const int MaxEdge = 1600;
    private const long JpegQuality = 80;
    private static readonly ImageCodecInfo JpegCodec =
        ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);

    public static CaptureSet CaptureAll(CancellationToken cancellationToken)
    {
        var displays = Displays.Enumerate();
        if (displays.Count == 0)
            throw new InvalidOperationException("No displays are available to capture. Reconnect your display and try again.");

        var capturedAt = DateTimeOffset.Now;
        var screens = new List<CapturedScreen>(displays.Count);
        for (var i = 0; i < displays.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            screens.Add(Capture(displays[i], i + 1));
        }
        return new CaptureSet(screens, capturedAt);
    }

    private static CapturedScreen Capture(DisplayInfo display, int screenIndex)
    {
        var bounds = display.Bounds;
        using var full = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb);
        using (var graphics = Graphics.FromImage(full))
        {
            graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
        }

        var scale = Math.Min(1.0, (double)MaxEdge / Math.Max(bounds.Width, bounds.Height));
        var width = Math.Max(1, (int)Math.Round(bounds.Width * scale));
        var height = Math.Max(1, (int)Math.Round(bounds.Height * scale));
        using var scaled = new Bitmap(width, height, PixelFormat.Format24bppRgb);
        using (var graphics = Graphics.FromImage(scaled))
        {
            graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
            graphics.DrawImage(full, 0, 0, width, height);
        }

        byte[] jpeg;
        using (var stream = new MemoryStream())
        using (var parameters = new EncoderParameters(1))
        {
            parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, JpegQuality);
            scaled.Save(stream, JpegCodec, parameters);
            jpeg = stream.ToArray();
        }

        var preview = new BitmapImage();
        preview.BeginInit();
        preview.CacheOption = BitmapCacheOption.OnLoad;
        preview.StreamSource = new MemoryStream(jpeg);
        preview.EndInit();
        preview.Freeze();

        return new CapturedScreen(display, new ScreenImage(screenIndex, display.Id, jpeg, width, height), preview);
    }
}
