using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Media.Imaging;
using FDistractions.App.Capture;
using FDistractions.App.Interop;
using FDistractions.Core;

namespace FDistractions.App.Overlays;

/// <summary>
/// Owns the blur + card windows for each blurred monitor. It only does what it's told:
/// the decision to start or clear blur lives in <see cref="InterventionState"/>.
/// </summary>
internal sealed class OverlayManager
{
    private static readonly TimeSpan ReturnFade = TimeSpan.FromMilliseconds(450);

    private sealed record Panels(BlurOverlayWindow Blur, CardWindow Card);

    private readonly Dictionary<string, Panels> _panels = new();

    /// <summary>Raised with the display id when "Return to work" is clicked on that screen's card.</summary>
    public event Action<string>? ReturnRequested;

    public IReadOnlyCollection<string> ActiveDisplayIds => _panels.Keys.ToList();

    public void Show(Intervention intervention, DisplayInfo display, BitmapSource snapshot, string goal)
    {
        if (_panels.TryGetValue(intervention.DisplayId, out var existing))
        {
            existing.Card.SetIntervention(intervention);
            return;
        }
        var blur = new BlurOverlayWindow(display, snapshot);
        var card = new CardWindow(display, goal, intervention);
        var displayId = intervention.DisplayId;
        card.ReturnClicked += () => ReturnRequested?.Invoke(displayId);
        _panels[displayId] = new Panels(blur, card);
        blur.Show();
        card.Show(); // shown second so it sits above the blur
    }

    public void Update(Intervention intervention)
    {
        if (_panels.TryGetValue(intervention.DisplayId, out var panels)) panels.Card.SetIntervention(intervention);
    }

    /// <summary>"Return to work": fade only this screen's blur and card away over 450 ms.</summary>
    public void AnimateOut(string displayId)
    {
        if (!_panels.Remove(displayId, out var panels)) return;
        WindowInterop.FadeOutAndClose(panels.Blur, ReturnFade);
        WindowInterop.FadeOutAndClose(panels.Card, ReturnFade);
    }

    public void Remove(string displayId)
    {
        if (!_panels.Remove(displayId, out var panels)) return;
        panels.Blur.Close();
        panels.Card.Close();
    }

    public void HideAll()
    {
        foreach (var id in _panels.Keys.ToList()) Remove(id);
    }
}
