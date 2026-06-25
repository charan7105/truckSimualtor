using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace MatrackSim.App.Controls
{
    /// <summary>Glass fuel tank with a gently moving liquid surface — mirrors Gauges.swift FuelCylinder.</summary>
    public sealed class FuelCylinder : FrameworkElement
    {
        public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
            nameof(Value), typeof(double), typeof(FuelCylinder),
            new FrameworkPropertyMetadata(60.0, FrameworkPropertyMetadataOptions.AffectsRender));
        public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }

        public static readonly DependencyProperty TintProperty = DependencyProperty.Register(
            nameof(Tint), typeof(Color), typeof(FuelCylinder),
            new FrameworkPropertyMetadata(Colors.LimeGreen, FrameworkPropertyMetadataOptions.AffectsRender));
        public Color Tint { get => (Color)GetValue(TintProperty); set => SetValue(TintProperty, value); }

        private static readonly Color Bg0 = (Color)ColorConverter.ConvertFromString("#08090B");
        private static readonly Color Bg1 = (Color)ColorConverter.ConvertFromString("#101217");
        private static readonly Color StrokeC = (Color)ColorConverter.ConvertFromString("#2A2E37");

        private double _phaseDeg;
        private readonly DispatcherTimer _timer;

        public FuelCylinder()
        {
            Width = 50; Height = 110;
            _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(60) };
            _timer.Tick += (s, e) => { _phaseDeg = (_phaseDeg + 7.2) % 360; InvalidateVisual(); };   // 3.0s/cycle
            Loaded += (s, e) => _timer.Start();
            Unloaded += (s, e) => _timer.Stop();
        }

        protected override Size MeasureOverride(Size availableSize) => new Size(50, 110);

        protected override void OnRender(DrawingContext dc)
        {
            double w = ActualWidth, h = ActualHeight;
            double radius = w * 0.46;
            var shape = new RectangleGeometry(new Rect(0, 0, w, h), radius, radius);
            double level = Math.Max(0, Math.Min(1, Value / 100.0));

            // glass body
            var body = new LinearGradientBrush(
                Color.FromArgb(191, Bg1.R, Bg1.G, Bg1.B),
                Color.FromArgb(153, Bg0.R, Bg0.G, Bg0.B), 90);
            dc.DrawGeometry(body, null, shape);

            // liquid wave (clipped to the tank)
            dc.PushClip(shape);
            double yBase = h * (1 - level);
            var wave = new StreamGeometry();
            using (var ctx = wave.Open())
            {
                ctx.BeginFigure(new Point(0, h), true, true);
                ctx.LineTo(new Point(0, yBase), true, false);
                double amplitude = 2.0;   // matches macOS FuelCylinder Wave(amplitude: 2)
                for (double x = 0; x <= w; x += 2)
                {
                    double rel = x / Math.Max(1, w);
                    double y = yBase + Math.Sin(rel * 2 * Math.PI * 1.6 + _phaseDeg * Math.PI / 180) * amplitude;
                    ctx.LineTo(new Point(x, y), true, false);
                }
                ctx.LineTo(new Point(w, h), true, false);
            }
            wave.Freeze();
            var liquid = new LinearGradientBrush(
                Color.FromArgb(242, Tint.R, Tint.G, Tint.B),
                Color.FromArgb(128, Tint.R, Tint.G, Tint.B),
                new Point(0, 1), new Point(0, 0));
            dc.DrawGeometry(liquid, null, wave);
            dc.Pop();

            // gloss
            var gloss = new LinearGradientBrush(
                Color.FromArgb(36, 255, 255, 255), Color.FromArgb(0, 255, 255, 255),
                new Point(0, 0), new Point(0.5, 0.5));
            dc.DrawGeometry(gloss, null, shape);

            // rim
            dc.DrawGeometry(null, new Pen(new SolidColorBrush(StrokeC), 1.5), shape);
        }
    }
}
