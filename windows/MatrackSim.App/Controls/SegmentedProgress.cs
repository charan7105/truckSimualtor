using System;
using System.Windows;
using System.Windows.Media;

namespace MatrackSim.App.Controls
{
    /// <summary>24-cell segmented HUD progress bar — mirrors Theme.swift SegmentedProgress.</summary>
    public sealed class SegmentedProgress : FrameworkElement
    {
        public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(
            nameof(Progress), typeof(double), typeof(SegmentedProgress),
            new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
        public double Progress { get => (double)GetValue(ProgressProperty); set => SetValue(ProgressProperty, value); }

        public static readonly DependencyProperty TintProperty = DependencyProperty.Register(
            nameof(Tint), typeof(Color), typeof(SegmentedProgress),
            new FrameworkPropertyMetadata((Color)ColorConverter.ConvertFromString("#32D74B"), FrameworkPropertyMetadataOptions.AffectsRender));
        public Color Tint { get => (Color)GetValue(TintProperty); set => SetValue(TintProperty, value); }

        private const int Cells = 24;
        private const double Gap = 3, CellH = 6;
        private static readonly Color IceDim = (Color)ColorConverter.ConvertFromString("#2E5A6E");

        protected override Size MeasureOverride(Size a) => new Size(double.IsInfinity(a.Width) ? 240 : a.Width, CellH);

        protected override void OnRender(DrawingContext dc)
        {
            double w = ActualWidth;
            if (w <= 0) return;
            double cellW = (w - (Cells - 1) * Gap) / Cells;
            int filled = Math.Max(0, Math.Min(Cells, (int)Math.Round(Progress * Cells)));
            var on = new SolidColorBrush(Tint);
            var off = new SolidColorBrush(Color.FromArgb(128, IceDim.R, IceDim.G, IceDim.B));
            double y = (ActualHeight - CellH) / 2;
            for (int i = 0; i < Cells; i++)
            {
                double x = i * (cellW + Gap);
                var rect = new RectangleGeometry(new Rect(x, y, cellW, CellH), 1.5, 1.5);
                dc.DrawGeometry(i < filled ? on : off, null, rect);
                if (i < filled)
                    dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(179, Tint.R, Tint.G, Tint.B)), null,   // glow 0.70 like macOS (was 0.47)
                        new RectangleGeometry(new Rect(x - 1, y - 1, cellW + 2, CellH + 2), 2, 2));
            }
        }
    }
}
