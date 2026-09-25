using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Button=System.Windows.Controls.Button;
namespace Rewind;
static class NativeMotion {
    public static void Install(){
        EventManager.RegisterClassHandler(typeof(Button),Mouse.MouseEnterEvent,new System.Windows.Input.MouseEventHandler((s,_)=>Scale((Button)s,1.018)));
        EventManager.RegisterClassHandler(typeof(Button),Mouse.MouseLeaveEvent,new System.Windows.Input.MouseEventHandler((s,_)=>Scale((Button)s,1)));
        EventManager.RegisterClassHandler(typeof(Button),Mouse.PreviewMouseDownEvent,new MouseButtonEventHandler((s,_)=>Scale((Button)s,.975)));
        EventManager.RegisterClassHandler(typeof(Button),Mouse.PreviewMouseUpEvent,new MouseButtonEventHandler((s,_)=>Scale((Button)s,1.018)));
    }
    private static void Scale(Button button,double target){
        if(!SystemParameters.ClientAreaAnimation||!button.IsEnabled||button.ActualWidth<25)return;
        if(button.RenderTransform is not ScaleTransform){button.RenderTransformOrigin=new Point(.5,.5);button.RenderTransform=new ScaleTransform(1,1);}
        var scale=(ScaleTransform)button.RenderTransform;var animation=new DoubleAnimation(target,TimeSpan.FromMilliseconds(160)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}};
        scale.BeginAnimation(ScaleTransform.ScaleXProperty,animation);scale.BeginAnimation(ScaleTransform.ScaleYProperty,animation);
    }
}
