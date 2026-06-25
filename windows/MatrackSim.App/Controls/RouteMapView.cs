using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using MatrackSim.Core;

namespace MatrackSim.App.Controls
{
    /// <summary>
    /// Schematic navigation map — the WPF stand-in for the MapKit ClusterMap. There are no street tiles
    /// (MapKit is Apple-only), so this draws the route polyline projected into the panel plus a smoothly
    /// eased truck marker, on a subtle grid. The route geometry + live position come straight from the
    /// view-model, exactly like the Swift Coordinator's render loop.
    /// </summary>
    public sealed class RouteMapView : FrameworkElement
    {
        private static readonly Color Ice = (Color)ColorConverter.ConvertFromString("#6FD3FF");
        private static readonly Color Red = (Color)ColorConverter.ConvertFromString("#E2122B");
        private static readonly Color Bg = (Color)ColorConverter.ConvertFromString("#0C0E13");
        private static readonly Color Grid = (Color)ColorConverter.ConvertFromString("#1A2A2E37");

        private readonly DispatcherTimer _timer;
        private double _dispLat, _dispLon;
        private bool _have;

        public RouteMapView()
        {
            _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
            _timer.Tick += (s, e) => InvalidateVisual();
            Loaded += (s, e) => _timer.Start();
            Unloaded += (s, e) => _timer.Stop();
        }

        private TrackerPeripheral Sim => DataContext as TrackerPeripheral;

        protected override void OnRender(DrawingContext dc)
        {
            double w = ActualWidth, h = ActualHeight;
            if (w <= 0 || h <= 0) return;
            var bg = new RectangleGeometry(new Rect(0, 0, w, h));
            dc.DrawGeometry(new SolidColorBrush(Bg), null, bg);

            // faint grid for a map-ish feel
            var gridPen = new Pen(new SolidColorBrush(Grid), 1);
            for (double x = 0; x < w; x += 48) dc.DrawLine(gridPen, new Point(x, 0), new Point(x, h));
            for (double y = 0; y < h; y += 48) dc.DrawLine(gridPen, new Point(0, y), new Point(w, y));

            var sim = Sim;
            if (sim == null) return;

            List<Coordinate> coords = sim.RouteCoords;
            bool hasRoute = coords != null && coords.Count >= 2;

            // ease the truck position toward the live one (≈0.20s time-constant @ 30fps)
            double curLat = sim.CurrentLat, curLon = sim.CurrentLon;
            if (!_have) { _dispLat = curLat; _dispLon = curLon; _have = true; }
            double f = 1 - Math.Exp(-(1.0 / 30.0) / 0.20);
            _dispLat += (curLat - _dispLat) * f;
            _dispLon += (curLon - _dispLon) * f;

            // projection bounds: the whole route (plus the truck), padded
            double minLat, maxLat, minLon, maxLon;
            if (hasRoute)
            {
                minLat = double.MaxValue; maxLat = double.MinValue; minLon = double.MaxValue; maxLon = double.MinValue;
                foreach (var c in coords)
                {
                    minLat = Math.Min(minLat, c.Latitude); maxLat = Math.Max(maxLat, c.Latitude);
                    minLon = Math.Min(minLon, c.Longitude); maxLon = Math.Max(maxLon, c.Longitude);
                }
            }
            else
            {
                minLat = _dispLat - 0.12; maxLat = _dispLat + 0.12;
                minLon = _dispLon - 0.12; maxLon = _dispLon + 0.12;
            }
            // guard against degenerate spans
            if (maxLat - minLat < 1e-4) { minLat -= 0.05; maxLat += 0.05; }
            if (maxLon - minLon < 1e-4) { minLon -= 0.05; maxLon += 0.05; }

            double pad = 28;
            double latSpan = maxLat - minLat, lonSpan = maxLon - minLon;
            double sx = (w - 2 * pad) / lonSpan;
            double sy = (h - 2 * pad) / latSpan;
            double s = Math.Min(sx, sy);
            double offX = pad + ((w - 2 * pad) - lonSpan * s) / 2;
            double offY = pad + ((h - 2 * pad) - latSpan * s) / 2;

            Func<double, double, Point> project = (lat, lon) =>
                new Point(offX + (lon - minLon) * s, offY + (maxLat - lat) * s);   // north = up

            // route polyline
            if (hasRoute)
            {
                var geo = new StreamGeometry();
                using (var ctx = geo.Open())
                {
                    Point p0 = project(coords[0].Latitude, coords[0].Longitude);
                    ctx.BeginFigure(p0, false, false);
                    for (int i = 1; i < coords.Count; i++)
                        ctx.LineTo(project(coords[i].Latitude, coords[i].Longitude), true, true);
                }
                geo.Freeze();
                var pen = new Pen(new SolidColorBrush(Color.FromArgb(242, Ice.R, Ice.G, Ice.B)), 5)
                { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
                dc.DrawGeometry(null, pen, geo);
            }

            // truck marker
            bool show = hasRoute || sim.DrivingRoute || sim.RouteProgress > 0;
            if (show)
            {
                Point tp = project(_dispLat, _dispLon);
                dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(90, Red.R, Red.G, Red.B)), null, tp, 13, 13);
                dc.DrawEllipse(new SolidColorBrush(Red), new Pen(new SolidColorBrush(Colors.White), 1.5), tp, 7, 7);
            }
        }
    }
}
