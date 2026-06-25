using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using MatrackSim.Core;

namespace MatrackSim.App
{
    /// <summary>
    /// Windows route provider — the stand-in for the Mac's MapKit Directions. Geocodes "City, ST" via
    /// OpenStreetMap Nominatim and fetches a real road route via the public OSRM server (both keyless).
    /// Falls back to a built-in city table + a smooth synthetic line when offline, so DRIVE / RANDOM /
    /// DRIVE MY DAY always produce a drivable route.
    /// </summary>
    public static class WindowsRouting
    {
        private static readonly HttpClient Http = CreateClient();
        private static HttpClient CreateClient()
        {
            var c = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
            // Nominatim's usage policy requires an identifying User-Agent.
            c.DefaultRequestHeaders.Add("User-Agent", "MatrackTruckSim/1.0 (windows simulator)");
            return c;
        }

        // Built-in coordinates for the cities the sim picks from (offline-safe geocoding fallback).
        private static readonly Dictionary<string, Coordinate> Cities = new Dictionary<string, Coordinate>(StringComparer.OrdinalIgnoreCase)
        {
            ["Dallas, TX"] = new Coordinate(32.7767, -96.7970),
            ["Houston, TX"] = new Coordinate(29.7604, -95.3698),
            ["Oklahoma City, OK"] = new Coordinate(35.4676, -97.5164),
            ["Los Angeles, CA"] = new Coordinate(34.0522, -118.2437),
            ["San Diego, CA"] = new Coordinate(32.7157, -117.1611),
            ["Chicago, IL"] = new Coordinate(41.8781, -87.6298),
            ["Milwaukee, WI"] = new Coordinate(43.0389, -87.9065),
            ["Indianapolis, IN"] = new Coordinate(39.7684, -86.1581),
            ["Phoenix, AZ"] = new Coordinate(33.4484, -112.0740),
            ["Tucson, AZ"] = new Coordinate(32.2226, -110.9747),
            ["Las Vegas, NV"] = new Coordinate(36.1699, -115.1398),
            ["Atlanta, GA"] = new Coordinate(33.7490, -84.3880),
            ["Macon, GA"] = new Coordinate(32.8407, -83.6324),
            ["Nashville, TN"] = new Coordinate(36.1627, -86.7816),
            ["Denver, CO"] = new Coordinate(39.7392, -104.9903),
            ["Colorado Springs, CO"] = new Coordinate(38.8339, -104.8214),
            ["Seattle, WA"] = new Coordinate(47.6062, -122.3321),
            ["Portland, OR"] = new Coordinate(45.5152, -122.6784),
            ["Miami, FL"] = new Coordinate(25.7617, -80.1918),
            ["Orlando, FL"] = new Coordinate(28.5383, -81.3792),
            ["New York, NY"] = new Coordinate(40.7128, -74.0060),
            ["Philadelphia, PA"] = new Coordinate(39.9526, -75.1652),
            ["San Francisco, CA"] = new Coordinate(37.7749, -122.4194),
            ["Sacramento, CA"] = new Coordinate(38.5816, -121.4944),
            ["Kansas City, MO"] = new Coordinate(39.0997, -94.5786),
            ["Omaha, NE"] = new Coordinate(41.2565, -95.9345),
        };

        public static async Task<List<Coordinate>> RouteAsync(string from, string to)
        {
            Coordinate a = await GeocodeAsync(from);
            Coordinate b = await GeocodeAsync(to);

            // Try a real road route from OSRM; if it fails, synthesize a smooth line.
            try
            {
                string url = "https://router.project-osrm.org/route/v1/driving/" +
                    $"{a.Longitude.ToString("F6", CultureInfo.InvariantCulture)},{a.Latitude.ToString("F6", CultureInfo.InvariantCulture)};" +
                    $"{b.Longitude.ToString("F6", CultureInfo.InvariantCulture)},{b.Latitude.ToString("F6", CultureInfo.InvariantCulture)}" +
                    "?overview=full&geometries=geojson";
                using var doc = JsonDocument.Parse(await Http.GetStringAsync(url));
                var coords = doc.RootElement.GetProperty("routes")[0].GetProperty("geometry").GetProperty("coordinates");
                var pts = new List<Coordinate>(coords.GetArrayLength());
                foreach (var p in coords.EnumerateArray())
                    pts.Add(new Coordinate(p[1].GetDouble(), p[0].GetDouble()));   // GeoJSON is [lon,lat]
                if (pts.Count >= 2) return pts;
            }
            catch { /* offline / OSRM down — fall through to synthetic */ }

            return Synthesize(a, b);
        }

        private static async Task<Coordinate> GeocodeAsync(string query)
        {
            if (Cities.TryGetValue(query.Trim(), out var known)) return known;
            try
            {
                string url = "https://nominatim.openstreetmap.org/search?format=json&limit=1&q=" + Uri.EscapeDataString(query);
                using var doc = JsonDocument.Parse(await Http.GetStringAsync(url));
                var first = doc.RootElement[0];
                double lat = double.Parse(first.GetProperty("lat").GetString(), CultureInfo.InvariantCulture);
                double lon = double.Parse(first.GetProperty("lon").GetString(), CultureInfo.InvariantCulture);
                return new Coordinate(lat, lon);
            }
            catch
            {
                // last resort: center of the continental US so the sim still has something to drive
                return new Coordinate(39.5, -98.35);
            }
        }

        /// <summary>A gently-curved interpolated line between two points (used when no road route is available).</summary>
        private static List<Coordinate> Synthesize(Coordinate a, Coordinate b)
        {
            const int n = 64;
            var pts = new List<Coordinate>(n + 1);
            // perpendicular offset for a subtle arc so it doesn't read as a dead-straight ruler line
            double midLat = (a.Latitude + b.Latitude) / 2, midLon = (a.Longitude + b.Longitude) / 2;
            double dLat = b.Latitude - a.Latitude, dLon = b.Longitude - a.Longitude;
            double bowLat = -dLon * 0.06, bowLon = dLat * 0.06;
            for (int i = 0; i <= n; i++)
            {
                double t = (double)i / n;
                double w = 4 * t * (1 - t);   // 0 at ends, 1 at middle
                double lat = a.Latitude + dLat * t + bowLat * w;
                double lon = a.Longitude + dLon * t + bowLon * w;
                pts.Add(new Coordinate(lat, lon));
            }
            return pts;
        }
    }
}
