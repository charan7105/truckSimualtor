using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace MatrackSim.App.Controls
{
    // ---- App logo (truck wheel) — native rebuild of HaulLogo.swift ----------------------------------
    public sealed class HaulLogo : FrameworkElement
    {
        public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(
            nameof(Size), typeof(double), typeof(HaulLogo),
            new FrameworkPropertyMetadata(30.0, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.AffectsMeasure));
        public double Size { get => (double)GetValue(SizeProperty); set => SetValue(SizeProperty, value); }

        protected override Size MeasureOverride(Size a) => new Size(Size, Size);

        protected override void OnRender(DrawingContext dc)
        {
            double size = Size, s = size / 100.0, c = size / 2;
            var bg = new LinearGradientBrush(
                (Color)ColorConverter.ConvertFromString("#2B2F3A"),
                (Color)ColorConverter.ConvertFromString("#0C0E14"),
                new Point(0, 0), new Point(1, 1));
            var white = Brushes.White;
            var rr = new RectangleGeometry(new Rect(0, 0, size, size), 22 * s, 22 * s);
            dc.DrawGeometry(bg, null, rr);
            // glossy top highlight (mirrors the Swift overlay gradient)
            dc.DrawGeometry(new LinearGradientBrush(
                Color.FromArgb(36, 255, 255, 255), Color.FromArgb(0, 255, 255, 255),
                new Point(0, 0), new Point(0, 0.5)), null, rr);
            dc.DrawEllipse(white, null, new Point(c, c), 31 * s, 31 * s);   // wheel ring
            dc.DrawEllipse(bg, null, new Point(c, c), 20.5 * s, 20.5 * s);  // ring inner
            dc.DrawEllipse(white, null, new Point(c, c), 9.5 * s, 9.5 * s); // hub
            foreach (double ang in new[] { 0.0, 120.0, 240.0 })
            {
                dc.PushTransform(new RotateTransform(ang, c, c));
                var spoke = new RectangleGeometry(new Rect(c - 4 * s, c, 8 * s, 22 * s), 4 * s, 4 * s);
                dc.DrawGeometry(white, null, spoke);
                dc.Pop();
            }
            var marker = new RectangleGeometry(new Rect(c - 2.5 * s, c - 29.5 * s, 5 * s, 6 * s), 2.2 * s, 2.2 * s);
            dc.DrawGeometry(bg, null, marker);
        }
    }

    // ---- Gear indicator (P R N D) -------------------------------------------------------------------
    public sealed class GearIndicator : FrameworkElement
    {
        public static readonly DependencyProperty GearProperty = DependencyProperty.Register(
            nameof(Gear), typeof(string), typeof(GearIndicator),
            new FrameworkPropertyMetadata("P", FrameworkPropertyMetadataOptions.AffectsRender));
        public string Gear { get => (string)GetValue(GearProperty); set => SetValue(GearProperty, value); }

        private static readonly string[] Gears = { "P", "R", "N", "D" };
        private static readonly Color Ice = (Color)ColorConverter.ConvertFromString("#6FD3FF");
        private static readonly Color Bg0 = (Color)ColorConverter.ConvertFromString("#08090B");
        private static readonly Color Dimmer = (Color)ColorConverter.ConvertFromString("#4A515E");

        private const double CellW = 32, CellH = 28, Gap = 10, PadX = 12, PadY = 8;

        protected override Size MeasureOverride(Size a) =>
            new Size(PadX * 2 + Gears.Length * CellW + (Gears.Length - 1) * Gap, PadY * 2 + CellH);

        protected override void OnRender(DrawingContext dc)
        {
            double x = PadX, y = PadY;
            var tf = new Typeface(new FontFamily("Segoe UI Variable Display, Segoe UI"), FontStyles.Normal, FontWeights.Black, FontStretches.Normal);
            foreach (var g in Gears)
            {
                bool on = g == Gear;
                if (on)
                {
                    var cell = new RectangleGeometry(new Rect(x, y, CellW, CellH), 8, 8);
                    dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(60, Ice.R, Ice.G, Ice.B)), null,
                        new RectangleGeometry(new Rect(x - 2, y - 2, CellW + 4, CellH + 4), 9, 9));
                    dc.DrawGeometry(new SolidColorBrush(Ice), null, cell);
                }
                var ft = new FormattedText(g, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, tf, 13,
                    new SolidColorBrush(on ? Bg0 : Dimmer), VisualTreeHelper.GetDpi(this).PixelsPerDip);
                dc.DrawText(ft, new Point(x + (CellW - ft.Width) / 2, y + (CellH - ft.Height) / 2));
                x += CellW + Gap;
            }
        }
    }

    // ---- Compass rose -------------------------------------------------------------------------------
    public sealed class CompassRose : FrameworkElement
    {
        public static readonly DependencyProperty HeadingDegProperty = DependencyProperty.Register(
            nameof(HeadingDeg), typeof(int), typeof(CompassRose),
            new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));
        public int HeadingDeg { get => (int)GetValue(HeadingDegProperty); set => SetValue(HeadingDegProperty, value); }

        public static readonly DependencyProperty CardinalProperty = DependencyProperty.Register(
            nameof(Cardinal), typeof(string), typeof(CompassRose),
            new FrameworkPropertyMetadata("N", FrameworkPropertyMetadataOptions.AffectsRender));
        public string Cardinal { get => (string)GetValue(CardinalProperty); set => SetValue(CardinalProperty, value); }

        private static readonly Color Bg0 = (Color)ColorConverter.ConvertFromString("#08090B");
        private static readonly Color StrokeC = (Color)ColorConverter.ConvertFromString("#2A2E37");
        private static readonly Color Red = (Color)ColorConverter.ConvertFromString("#E2122B");
        private static readonly Color TextC = (Color)ColorConverter.ConvertFromString("#F4F6FA");
        private static readonly Color DimC = (Color)ColorConverter.ConvertFromString("#868E9C");

        protected override Size MeasureOverride(Size a) => new Size(88, 88);

        protected override void OnRender(DrawingContext dc)
        {
            double c = 44;
            dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(179, Bg0.R, Bg0.G, Bg0.B)), null, new Point(c, c), c, c);
            dc.DrawEllipse(null, new Pen(new SolidColorBrush(StrokeC), 1), new Point(c, c), c, c);

            // rotating N marker
            dc.PushTransform(new RotateTransform(-HeadingDeg, c, c));
            var nf = new Typeface(new FontFamily("Segoe UI Variable Display, Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
            var nt = new FormattedText("N", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, nf, 10,
                new SolidColorBrush(Red), VisualTreeHelper.GetDpi(this).PixelsPerDip);
            dc.DrawText(nt, new Point(c - nt.Width / 2, c - 32 - nt.Height / 2));
            dc.Pop();

            var hf = new Typeface(new FontFamily("Segoe UI Variable Display, Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
            var ht = new FormattedText($"{HeadingDeg}°", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, hf, 16,
                new SolidColorBrush(TextC), VisualTreeHelper.GetDpi(this).PixelsPerDip);
            var ct = new FormattedText(Cardinal ?? "", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, hf, 10,
                new SolidColorBrush(DimC), VisualTreeHelper.GetDpi(this).PixelsPerDip);
            dc.DrawText(ht, new Point(c - ht.Width / 2, c - ht.Height / 2 - 4));
            dc.DrawText(ct, new Point(c - ct.Width / 2, c + 6));
        }
    }
}
