using Microsoft.UI.Xaml.Automation.Peers;

namespace Recall;

/// Keeps retained visuals connected without exposing their controls while hidden.
/// AccessibilityView.Raw on the container alone still exposes its descendants.
internal sealed class AccessibilityGrid : Grid
{
    internal bool ExposeChildren { get; set; } = true;

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    sealed class Peer(AccessibilityGrid owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override IList<AutomationPeer> GetChildrenCore() =>
            owner.ExposeChildren ? base.GetChildrenCore() : Array.Empty<AutomationPeer>();

        protected override bool IsControlElementCore() => false;
        protected override bool IsContentElementCore() => false;
    }
}
