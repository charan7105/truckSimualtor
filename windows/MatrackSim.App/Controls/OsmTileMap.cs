using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using MatrackSim.Core;

namespace MatrackSim.App.Controls
{
    /// <summary>
    /// Pure-WPF slippy map rendering CARTO "Voyager" raster tiles — a light, colourful Google/Apple-style
    /// basemap (the Windows stand-in for MapKit's ClusterMap). Being a normal WPF element (not a WebView2
    /// HwndHost), it scales correctly inside the cluster's scale-to-fit Viewbox. Draws a white-cased blue
    /// route polyline + an eased truck marker, fits the route when idle and follows the truck while driving,
    /// exactly like the Swift Coordinator. No API key required.
    /// </summary>
    public sealed class OsmTileMap : FrameworkElement
    {
        private const int TileSize = 256;
        private static readonly HttpClient Http = CreateClient();
        private static HttpClient CreateClient()
        {
            var c = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            c.DefaultRequestHeaders.Add("User-Agent", "MatrackTruckSim/1.0 (windows simulator)");
            return c;
        }

        private readonly Dictionary<string, ImageSource> _cache = new Dictionary<string, ImageSource>();
        private readonly HashSet<string> _loading = new HashSet<string>();
        private readonly DispatcherTimer _timer;
        private double _dispLat = 37.7869, _dispLon = -121.9777;
        private bool _have;
        private static readonly Color RouteBlue = (Color)ColorConverter.ConvertFromString("#2D7DF6"); // Google/Apple route blue
        private static readonly Color Red = (Color)ColorConverter.ConvertFromString("#E2122B");
        // Dark loading backdrop matching the CARTO dark tiles (shown only until tiles arrive).
        private static readonly Brush Bg = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#0C0E13"));

        public OsmTileMap()
        {
            ClipToBounds = true;
            _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(40) };
            _timer.Tick += (s, e) => InvalidateVisual();
            Loaded += (s, e) => _timer.Start();
            Unloaded += (s, e) => _timer.Stop();
        }

        private TrackerPeripheral Sim => DataContext as TrackerPeripheral;

        // ---- Web Mercator projection (world pixels at a given zoom) -------------------------------
        private static double WorldX(double lon, int z) => (lon + 180.0) / 360.0 * Math.Pow(2, z) * TileSize;
        private static double WorldY(double lat, int z)
        {
            double r = lat * Math.PI / 180.0;
            double y = (1 - Math.Log(Math.Tan(r) + 1.0 / Math.Cos(r)) / Math.PI) / 2;
            return y * Math.Pow(2, z) * TileSize;
        }

        protected override void OnRender(DrawingContext dc)
        {
            double w = ActualWidth, h = ActualHeight;
            if (w <= 0 || h <= 0) return;
            dc.DrawRectangle(Bg, null, new Rect(0, 0, w, h));

            var sim = Sim;
            List<Coordinate> coords = sim?.RouteCoords;
            bool hasRoute = coords != null && coords.Count >= 2;

            // ease the truck position toward the live one
            double curLat = sim?.CurrentLat ?? _dispLat, curLon = sim?.CurrentLon ?? _dispLon;
            if (!_have) { _dispLat = curLat; _dispLon = curLon; _have = true; }
            double f = 1 - Math.Exp(-0.04 / 0.20);
            _dispLat += (curLat - _dispLat) * f;
            _dispLon += (curLon - _dispLon) * f;

            bool driving = sim != null && sim.DrivingRoute;

            // choose center + zoom: fit route when idle, follow truck (closer) when driving
            double centerLat, centerLon; int zoom;
            if (hasRoute)
            {
                double minLat = double.MaxValue, maxLat = double.MinValue, minLon = double.MaxValue, maxLon = double.MinValue;
                foreach (var c in coords)
                {
                    minLat = Math.Min(minLat, c.Latitude); maxLat = Math.Max(maxLat, c.Latitude);
                    minLon = Math.Min(minLon, c.Longitude); maxLon = Math.Max(maxLon, c.Longitude);
                }
                int fitZoom = FitZoom(minLat, maxLat, minLon, maxLon, w, h);
                if (driving) { centerLat = _dispLat; centerLon = _dispLon; zoom = Math.Min(12, fitZoom + 2); }
                else { centerLat = (minLat + maxLat) / 2; centerLon = (minLon + maxLon) / 2; zoom = fitZoom; }
            }
            else { centerLat = _dispLat; centerLon = _dispLon; zoom = 6; }
            zoom = Math.Max(2, Math.Min(16, zoom));

            // top-left world pixel of the viewport
            double cwx = WorldX(centerLon, zoom), cwy = WorldY(centerLat, zoom);
            double topX = cwx - w / 2, topY = cwy - h / 2;
            int n = (int)Math.Pow(2, zoom);

            // draw tiles covering the viewport
            int minTileX = (int)Math.Floor(topX / TileSize), maxTileX = (int)Math.Floor((topX + w) / TileSize);
            int minTileY = (int)Math.Floor(topY / TileSize), maxTileY = (int)Math.Floor((topY + h) / TileSize);
            for (int tx = minTileX; tx <= maxTileX; tx++)
                for (int ty = minTileY; ty <= maxTileY; ty++)
                {
                    int wx = ((tx % n) + n) % n;   // wrap longitude
                    if (ty < 0 || ty >= n) continue;
                    var img = GetTile(zoom, wx, ty);
                    if (img == null) continue;
                    double px = tx * TileSize - topX, py = ty * TileSize - topY;
                    dc.DrawImage(img, new Rect(px, py, TileSize, TileSize));
                }

            // route polyline
            if (hasRoute)
            {
                var geo = new StreamGeometry();
                using (var ctx = geo.Open())
                {
                    ctx.BeginFigure(Project(coords[0].Latitude, coords[0].Longitude, zoom, topX, topY), false, false);
                    for (int i = 1; i < coords.Count; i++)
                        ctx.LineTo(Project(coords[i].Latitude, coords[i].Longitude, zoom, topX, topY), true, true);
                }
                geo.Freeze();
                // white casing under a blue core — the classic Apple/Google route look on a light map
                dc.DrawGeometry(null, new Pen(new SolidColorBrush(Color.FromArgb(235, 255, 255, 255)), 9)
                { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round }, geo);
                dc.DrawGeometry(null, new Pen(new SolidColorBrush(RouteBlue), 5.5)
                { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round }, geo);
            }

            // truck marker
            bool show = hasRoute || driving || (sim != null && sim.RouteProgress > 0);
            if (show)
            {
                Point tp = Project(_dispLat, _dispLon, zoom, topX, topY);
                dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(90, Red.R, Red.G, Red.B)), null, tp, 13, 13);
                dc.DrawEllipse(new SolidColorBrush(Red), new Pen(new SolidColorBrush(Colors.White), 2), tp, 7, 7);
            }
        }

        private static Point Project(double lat, double lon, int z, double topX, double topY) =>
            new Point(WorldX(lon, z) - topX, WorldY(lat, z) - topY);

        private static int FitZoom(double minLat, double maxLat, double minLon, double maxLon, double w, double h)
        {
            for (int z = 16; z >= 2; z--)
            {
                double dx = Math.Abs(WorldX(maxLon, z) - WorldX(minLon, z));
                double dy = Math.Abs(WorldY(minLat, z) - WorldY(maxLat, z));
                if (dx <= w - 56 && dy <= h - 56) return z;
            }
            return 3;
        }

        private ImageSource GetTile(int z, int x, int y)
        {
            string key = $"{z}/{x}/{y}";
            if (_cache.TryGetValue(key, out var img)) return img;
            if (!_loading.Contains(key)) { _loading.Add(key); _ = FetchTile(z, x, y, key); }
            return null;
        }

        private async System.Threading.Tasks.Task FetchTile(int z, int x, int y, string key)
        {
            char sub = "abc"[(x + y) % 3];
            string url = $"https://{sub}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png";   // dark tiles → match the Mac dark map
            try
            {
                byte[] bytes = await Http.GetByteArrayAsync(url);
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.StreamSource = new System.IO.MemoryStream(bytes);
                bmp.EndInit();
                bmp.Freeze();
                _cache[key] = bmp;
            }
            catch { /* offline / tile missing — leave the dark background */ }
            finally { _loading.Remove(key); InvalidateVisual(); }
        }
    }
}
