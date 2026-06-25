using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace MatrackSim.App.Controls
{
    /// <summary>
    /// Custom-drawn speedometer / tachometer dial — the WPF reproduction of Gauges.swift's GaugeRing.
    /// Convention (same as Swift): degrees measured clockwise from 12 o'clock; the dial starts at 225°
    /// (lower-left) and sweeps 270° clockwise to 135° (lower-right), leaving an open bottom.
    /// </summary>
    public sealed class DialGauge : FrameworkElement
    {
        public enum DialMode { Speed, Tach }

        private const double StartDeg = 225.0;
        private const double SweepDeg = 270.0;

        // ---- Dependency properties ---------------------------------------------------------------
        public static readonly DependencyProperty FractionProperty = DependencyProperty.Register(
            nameof(Fraction), typeof(double), typeof(DialGauge),
            new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
        public double Fraction { get => (double)GetValue(FractionProperty); set => SetValue(FractionProperty, value); }

        public static readonly DependencyProperty ModeProperty = DependencyProperty.Register(
            nameof(Mode), typeof(DialMode), typeof(DialGauge),
            new FrameworkPropertyMetadata(DialMode.Speed, FrameworkPropertyMetadataOptions.AffectsRender));
        public DialMode Mode { get => (DialMode)GetValue(ModeProperty); set => SetValue(ModeProperty, value); }

        public static readonly DependencyProperty CenterTextProperty = DependencyProperty.Register(
            nameof(CenterText), typeof(string), typeof(DialGauge),
            new FrameworkPropertyMetadata("0", FrameworkPropertyMetadataOptions.AffectsRender));
        public string CenterText { get => (string)GetValue(CenterTextProperty); set => SetValue(CenterTextProperty, value); }

        public static readonly DependencyProperty UnitProperty = DependencyProperty.Register(
            nameof(Unit), typeof(string), typeof(DialGauge),
            new FrameworkPropertyMetadata("KM/H", FrameworkPropertyMetadataOptions.AffectsRender));
        public string Unit { get => (string)GetValue(UnitProperty); set => SetValue(UnitProperty, value); }

        public static readonly DependencyProperty HotProperty = DependencyProperty.Register(
            nameof(Hot), typeof(bool), typeof(DialGauge),
            new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));
        public bool Hot { get => (bool)GetValue(HotProperty); set => SetValue(HotProperty, value); }

        // ---- Theme colours -----------------------------------------------------------------------
        private static readonly Color Ice = (Color)ColorConverter.ConvertFromString("#6FD3FF");
        private static readonly Color IceLt = (Color)ColorConverter.ConvertFromString("#9FE6FF");
        private static readonly Color Red = (Color)ColorConverter.ConvertFromString("#E2122B");
        private static readonly Color Amber = (Color)ColorConverter.ConvertFromString("#F5A623");
        private static readonly Color TextC = (Color)ColorConverter.ConvertFromString("#F4F6FA");
        private static readonly Color DimC = (Color)ColorConverter.ConvertFromString("#868E9C");
        private static readonly Color Bg0 = (Color)ColorConverter.ConvertFromString("#08090B");
        private static readonly Color StrokeC = (Color)ColorConverter.ConvertFromString("#2A2E37");

        protected override Size MeasureOverride(Size availableSize)
        {
            double d = double.IsInfinity(availableSize.Width) ? 300 : Math.Min(availableSize.Width, availableSize.Height);
            if (double.IsInfinity(d) || d <= 0) d = 300;
            return new Size(d, d);
        }

        private static double Deg2Rad(double d) => d * Math.PI / 180.0;
        private Point OnCircle(double cx, double cy, double r, double degFromUp)
        {
            double a = Deg2Rad(degFromUp);
            return new Point(cx + r * Math.Sin(a), cy - r * Math.Cos(a));
        }

        protected override void OnRender(DrawingContext dc)
        {
            double diameter = Math.Min(ActualWidth, ActualHeight);
            if (diameter <= 0) diameter = 300;
            double cx = ActualWidth / 2, cy = ActualHeight / 2;
            double f = Math.Max(0, Math.Min(1, Fraction));

            double lw = diameter * 0.060;
            double arcInset = diameter * 0.090;
            double arcR = diameter / 2 - arcInset;
            double tickR = diameter * 0.460;
            double labelR = diameter * 0.335;
            double faceD = diameter * 0.560;

            bool tach = Mode == DialMode.Tach;
            int tickCount = tach ? 36 : 40;
            int majorEvery = tach ? 6 : 8;
            double redTickFrom = tach ? 30.0 / 36.0 : 1.1;
            var arcStops = tach ? new[] { Ice, Amber, Red } : new[] { Ice, IceLt, Red };
            var labels = tach
                ? new (double, string)[] { (0, "0"), (0.333, "1k"), (0.667, "2k"), (1.0, "3k") }
                : new (double, string)[] { (0, "0"), (0.2, "40"), (0.4, "80"), (0.6, "120"), (0.8, "160"), (1.0, "200") };

            // ---- tick marks ----
            for (int i = 0; i <= tickCount; i++)
            {
                bool major = i % majorEvery == 0;
                bool inRed = (double)i / tickCount >= redTickFrom;
                double deg = StartDeg + SweepDeg * i / tickCount;
                double len = major ? diameter * 0.045 : diameter * 0.026;
                double w = major ? 2.5 : 1.5;
                Point outer = OnCircle(cx, cy, tickR + len / 2, deg);
                Point inner = OnCircle(cx, cy, tickR - len / 2, deg);
                Color tc = inRed ? Color.FromArgb((byte)(major ? 242 : 166), Red.R, Red.G, Red.B)
                                 : Color.FromArgb((byte)(major ? 90 : 31), 255, 255, 255);
                var pen = new Pen(new SolidColorBrush(tc), w) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
                dc.DrawLine(pen, inner, outer);
            }

            // ---- numbered labels ----
            foreach (var (frac, txt) in labels)
            {
                double deg = StartDeg + SweepDeg * frac;
                Point p = OnCircle(cx, cy, labelR, deg);
                var ft = MakeText(txt, diameter * 0.044, DimC, FontWeights.SemiBold);
                dc.DrawText(ft, new Point(p.X - ft.Width / 2, p.Y - ft.Height / 2));
            }

            // ---- track (faint full sweep) ----
            DrawArc(dc, cx, cy, arcR, StartDeg, StartDeg + SweepDeg,
                    new Pen(new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)), lw)
                    { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round });

            // ---- redline band (tach) ----
            if (tach)
            {
                double rlStart = StartDeg + SweepDeg * (30.0 / 36.0);
                DrawArc(dc, cx, cy, arcR, rlStart, StartDeg + SweepDeg,
                        new Pen(new SolidColorBrush(Color.FromArgb(230, Red.R, Red.G, Red.B)), lw)
                        { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round });
            }

            // ---- value arc (gradient, segmented to emulate the angular gradient) ----
            if (f > 0.0001)
            {
                int segs = Math.Max(2, (int)Math.Ceiling(200 * f));   // fine segments → smooth angular gradient
                for (int i = 0; i < segs; i++)
                {
                    double t0 = (double)i / segs * f;
                    double t1 = (double)(i + 1) / segs * f;
                    double d0 = StartDeg + SweepDeg * t0;
                    double d1 = StartDeg + SweepDeg * t1;
                    Color c = Lerp(arcStops, t1);   // gradient spans the value
                    var pen = new Pen(new SolidColorBrush(c), lw)
                    {
                        StartLineCap = PenLineCap.Round,
                        EndLineCap = PenLineCap.Round,
                    };
                    DrawArc(dc, cx, cy, arcR, d0, d1 + 0.6, pen);   // tiny overlap to avoid seams
                }
                // comet tip + glow
                double tipDeg = StartDeg + SweepDeg * f;
                Point tip = OnCircle(cx, cy, arcR, tipDeg);
                Color tipColor = tach ? (Hot ? Red : Amber) : Ice;
                var glow = new SolidColorBrush(Color.FromArgb(191, tipColor.R, tipColor.G, tipColor.B));
                dc.DrawEllipse(glow, null, tip, lw * 0.62, lw * 0.62);
                dc.DrawEllipse(new SolidColorBrush(tipColor), null, tip, lw * 0.31, lw * 0.31);
            }

            // ---- inner dial-face ----
            dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(128, Bg0.R, Bg0.G, Bg0.B)), null, new Point(cx, cy), faceD / 2, faceD / 2);
            dc.DrawEllipse(null, new Pen(new SolidColorBrush(StrokeC), 1), new Point(cx, cy), faceD / 2, faceD / 2);

            // ---- center readout ----
            Color bigColor = (tach && Hot) ? Red : TextC;
            double bigSize = tach ? diameter * 0.19 : diameter * 0.26;
            var big = MakeText(CenterText ?? "", bigSize, bigColor, FontWeights.Bold);
            var unit = MakeText(Unit ?? "", diameter * 0.045, (tach && Hot) ? Red : DimC, FontWeights.Bold, tracking: 6);
            double blockH = big.Height + unit.Height - 2;
            double topY = cy - blockH / 2;
            dc.DrawText(big, new Point(cx - big.Width / 2, topY));
            dc.DrawText(unit, new Point(cx - unit.Width / 2, topY + big.Height - 2));
        }

        private static void DrawArc(DrawingContext dc, double cx, double cy, double r, double startDeg, double endDeg, Pen pen)
        {
            var sg = new StreamGeometry();
            using (var ctx = sg.Open())
            {
                double a0 = Deg2Rad(startDeg), a1 = Deg2Rad(endDeg);
                Point p0 = new Point(cx + r * Math.Sin(a0), cy - r * Math.Cos(a0));
                Point p1 = new Point(cx + r * Math.Sin(a1), cy - r * Math.Cos(a1));
                ctx.BeginFigure(p0, false, false);
                bool large = (endDeg - startDeg) > 180.0;
                ctx.ArcTo(p1, new Size(r, r), 0, large, SweepDirection.Clockwise, true, false);
            }
            sg.Freeze();
            dc.DrawGeometry(null, pen, sg);
        }

        private static Color Lerp(Color[] stops, double t)
        {
            t = Math.Max(0, Math.Min(1, t));
            if (stops.Length == 1) return stops[0];
            double scaled = t * (stops.Length - 1);
            int i = (int)Math.Floor(scaled);
            if (i >= stops.Length - 1) return stops[stops.Length - 1];
            double local = scaled - i;
            Color a = stops[i], b = stops[i + 1];
            return Color.FromRgb(
                (byte)(a.R + (b.R - a.R) * local),
                (byte)(a.G + (b.G - a.G) * local),
                (byte)(a.B + (b.B - a.B) * local));
        }

        private static readonly Typeface Face = new Typeface(
            new FontFamily("Segoe UI Variable Display, Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);

        private FormattedText MakeText(string s, double size, Color color, FontWeight weight, double tracking = 0)
        {
            if (tracking > 0 && s.Length > 1)
            {
                var sb = new System.Text.StringBuilder();
                foreach (var ch in s) { sb.Append(ch); sb.Append(' '); }
                s = sb.ToString().TrimEnd();
            }
            var tf = new Typeface(new FontFamily("Segoe UI Variable Display, Segoe UI"), FontStyles.Normal, weight, FontStretches.Normal);
            return new FormattedText(s ?? "", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, tf, size,
                new SolidColorBrush(color), VisualTreeHelper.GetDpi(this).PixelsPerDip);
        }
    }
}
