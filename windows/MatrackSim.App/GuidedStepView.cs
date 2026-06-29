using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace MatrackSim.App
{
    // Step-by-step guided walkthrough card (mirrors the macOS GuidedStepView). Walks a scenario's
    // appSteps one instruction at a time; advancing past the "Run it" step fires the real sim action
    // (for the UDP / disconnect scenarios that's: drop the link, record the drive, dump it on reconnect),
    // so the tester is told exactly what to do in the ELD app at each moment.
    //
    // Unlike the old top-level dialog, this is an in-window control hosted by MainWindow's centered guided
    // overlay (a dim full-window scrim), matching the Mac flow where the walkthrough is centered on the
    // whole cockpit rather than anchored to a corner.
    public sealed class GuidedStepView : UserControl
    {
        private readonly string _title;
        private readonly IList<string> _steps;
        private readonly Action _onRun;
        private readonly Action _onClose;
        private int _step;

        private static SolidColorBrush B(string hex) => new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        private static readonly SolidColorBrush Bg = B("#101217"), Txt = B("#F4F6FA"), Amber = B("#F5A623"),
            Dim = B("#868E9C"), Stroke = B("#2A2E37"), Red = B("#E2122B"), Ice = B("#6FD3FF"), Dark = B("#08090B");

        public GuidedStepView(string title, IList<string> steps, Action onRun, Action onClose)
        {
            _title = title; _steps = steps ?? new List<string>(); _onRun = onRun; _onClose = onClose;
            Width = 460;
            Render();
        }

        private void Render()
        {
            if (_steps.Count == 0) { _onClose?.Invoke(); return; }
            bool isLast = _step + 1 >= _steps.Count;
            bool isRun = _steps[_step].ToUpperInvariant().Contains("RUN");

            var root = new StackPanel { Margin = new Thickness(26) };

            var header = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 0, 0, 14) };
            var hl = new TextBlock { Text = "GUIDED RUN", Foreground = Amber, FontWeight = FontWeights.Black, FontSize = 11 };
            DockPanel.SetDock(hl, Dock.Left);
            var hr = new TextBlock { Text = $"Step {_step + 1} of {_steps.Count}", Foreground = Dim, FontSize = 11 };
            DockPanel.SetDock(hr, Dock.Right);
            header.Children.Add(hl); header.Children.Add(hr);
            root.Children.Add(header);

            root.Children.Add(new TextBlock { Text = _title, Foreground = Ice, FontWeight = FontWeights.Bold, FontSize = 13, Margin = new Thickness(0, 0, 0, 10) });
            root.Children.Add(new TextBlock { Text = _steps[_step], Foreground = Txt, FontSize = 18, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 18) });

            var dots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 18) };
            for (int i = 0; i < _steps.Count; i++)
                dots.Children.Add(new Border { Width = i == _step ? 22 : 9, Height = 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 5, 0), Background = i <= _step ? Amber : Stroke });
            root.Children.Add(dots);

            var bar = new DockPanel { LastChildFill = false };
            var cancel = new Button { Content = "Cancel", Foreground = Dim, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand, FontSize = 13 };
            cancel.Click += (s, e) => _onClose?.Invoke();
            DockPanel.SetDock(cancel, Dock.Left);
            var next = new Button
            {
                Content = isLast ? "Done ✓" : (isRun ? "▶ Run it" : "Next →"),
                Foreground = isRun ? Txt : Dark, Background = isRun ? Red : Ice, BorderThickness = new Thickness(0),
                Padding = new Thickness(22, 9, 22, 9), FontSize = 13, FontWeight = FontWeights.SemiBold, Cursor = Cursors.Hand
            };
            next.Click += (s, e) => Advance();
            DockPanel.SetDock(next, Dock.Right);
            bar.Children.Add(cancel); bar.Children.Add(next);
            root.Children.Add(bar);

            Content = new Border
            {
                Background = Bg,
                CornerRadius = new CornerRadius(20),
                BorderBrush = Stroke,
                BorderThickness = new Thickness(1),
                Child = root,
                Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.6, BlurRadius = 44, ShadowDepth = 22, Direction = 270 },
            };
        }

        private void Advance()
        {
            if (_steps[_step].ToUpperInvariant().Contains("RUN")) { try { _onRun?.Invoke(); } catch { } }
            if (_step + 1 < _steps.Count) { _step++; Render(); }
            else _onClose?.Invoke();
        }
    }
}
