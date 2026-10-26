using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace MatrackSim.App
{
    // Low-fuel prompt card (mirrors the macOS lowFuelCard). The drain is the hook that pushes the tester
    // into the Matrack Fuel App; the ¼/½/¾/Full buttons "refuel at the station" (both tanks) and also
    // un-stall an empty truck. Hosted by MainWindow's centered LowFuelOverlay scrim.
    public sealed class LowFuelView : UserControl
    {
        private static SolidColorBrush B(string hex) => new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        private static readonly SolidColorBrush Bg = B("#16181E"), Txt = B("#F4F6FA"), Dim = B("#868E9C"),
            Red = B("#E2122B"), Green = B("#32D74B");

        public LowFuelView(double fuelPct, bool empty, Action<double> onRefuel, Action onClose)
        {
            Width = 452;
            var root = new StackPanel { Margin = new Thickness(24) };

            root.Children.Add(new TextBlock
            {
                Text = empty ? "OUT OF FUEL" : $"LOW FUEL · {(int)fuelPct}%",
                Foreground = Red, FontWeight = FontWeights.Bold, FontSize = 19, Margin = new Thickness(0, 0, 0, 12)
            });
            root.Children.Add(new TextBlock
            {
                Text = empty ? "The truck has stopped — both tanks are empty. Fill up to keep driving."
                             : "Fuel is running low. Time to find a station.",
                Foreground = Txt, FontSize = 13.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14)
            });

            AddStep(root, "1", "Open the Matrack Fuel App on your phone.");
            AddStep(root, "2", "Don't have it? Get it from truck-simualtor.vercel.app.");
            AddStep(root, "3", "Link it to this simulator — you'll see your current location.");
            AddStep(root, "4", "Find a nearby station, then fill up:");

            var btns = new UniformGrid { Columns = 4, Margin = new Thickness(0, 12, 0, 4) };
            AddRefuel(btns, "¼", 25, onRefuel);
            AddRefuel(btns, "½", 50, onRefuel);
            AddRefuel(btns, "¾", 75, onRefuel);
            AddRefuel(btns, "Full", 100, onRefuel);
            root.Children.Add(btns);

            var later = new Button
            {
                Content = "Later", Foreground = Dim, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
                Cursor = Cursors.Hand, FontSize = 13, Margin = new Thickness(0, 10, 0, 0), HorizontalAlignment = HorizontalAlignment.Center
            };
            later.Click += (s, e) => onClose?.Invoke();
            root.Children.Add(later);

            Content = new Border
            {
                Background = Bg, CornerRadius = new CornerRadius(20), BorderBrush = Red, BorderThickness = new Thickness(1),
                Child = root,
                Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.6, BlurRadius = 44, ShadowDepth = 22, Direction = 270 },
            };
        }

        private void AddStep(StackPanel root, string n, string text)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 7) };
            row.Children.Add(new Border
            {
                Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = B("#2732D74B"),
                Margin = new Thickness(0, 0, 9, 0), VerticalAlignment = VerticalAlignment.Top,
                Child = new TextBlock { Text = n, Foreground = Green, FontWeight = FontWeights.Bold, FontSize = 11,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
            });
            row.Children.Add(new TextBlock { Text = text, Foreground = B("#D9F4F6FA"), FontSize = 12.5,
                TextWrapping = TextWrapping.Wrap, MaxWidth = 360, VerticalAlignment = VerticalAlignment.Center });
            root.Children.Add(row);
        }

        private void AddRefuel(UniformGrid grid, string label, double pct, Action<double> onRefuel)
        {
            var btn = new Button
            {
                Content = label, Foreground = Green, Background = B("#2E32D74B"), BorderBrush = B("#8032D74B"),
                BorderThickness = new Thickness(1), Cursor = Cursors.Hand, FontSize = 15, FontWeight = FontWeights.Bold,
                Height = 42, Margin = new Thickness(4, 0, 4, 0)
            };
            btn.Click += (s, e) => onRefuel?.Invoke(pct);
            grid.Children.Add(btn);
        }
    }
}
