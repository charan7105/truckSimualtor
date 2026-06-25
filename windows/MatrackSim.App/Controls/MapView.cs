using System;
using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Wpf;
using MatrackSim.Core;

namespace MatrackSim.App.Controls
{
    /// <summary>
    /// Real navigation map using OpenStreetMap tiles via Leaflet inside a WebView2 — the Windows
    /// equivalent of the MapKit ClusterMap. No API key required (CARTO dark basemap + OSM data).
    /// The route polyline and live truck position are pushed in from the view-model, mirroring the
    /// Swift Coordinator's render loop. Falls back silently if the WebView2 runtime is unavailable.
    /// </summary>
    public sealed class MapView : Grid
    {
        private readonly WebView2 _web = new WebView2();
        private readonly DispatcherTimer _timer;
        private bool _ready;
        private int _lastRouteVersion = -1;
        private double _dispLat, _dispLon;
        private bool _have;

        public MapView()
        {
            Children.Add(_web);
            _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(40) };
            _timer.Tick += Tick;
            Loaded += async (s, e) =>
            {
                try
                {
                    await _web.EnsureCoreWebView2Async();
                    _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
                    _web.CoreWebView2.Settings.IsStatusBarEnabled = false;
                    _web.DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 12, 14, 19);
                    _web.NavigationCompleted += (a, b) => { _ready = true; };
                    _web.NavigateToString(Html);
                    _timer.Start();
                }
                catch { /* WebView2 runtime missing — leave the panel dark */ }
            };
            Unloaded += (s, e) => _timer.Stop();
        }

        private TrackerPeripheral Sim => DataContext as TrackerPeripheral;

        private async void Tick(object sender, EventArgs e)
        {
            if (!_ready) return;
            var sim = Sim;
            if (sim == null) return;

            // push a new route when the version bumps
            if (sim.RouteVersion != _lastRouteVersion)
            {
                _lastRouteVersion = sim.RouteVersion;
                var coords = sim.RouteCoords;
                var sb = new StringBuilder("[");
                if (coords != null)
                    for (int i = 0; i < coords.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        sb.Append('[').Append(coords[i].Latitude.ToString("F6", CultureInfo.InvariantCulture))
                          .Append(',').Append(coords[i].Longitude.ToString("F6", CultureInfo.InvariantCulture)).Append(']');
                    }
                sb.Append(']');
                await Exec($"setRoute({sb})");
                _have = false;   // re-seed the eased position for the new route
            }

            // ease the truck marker toward the live position
            double curLat = sim.CurrentLat, curLon = sim.CurrentLon;
            if (!_have) { _dispLat = curLat; _dispLon = curLon; _have = true; }
            double f = 1 - Math.Exp(-0.04 / 0.20);
            _dispLat += (curLat - _dispLat) * f;
            _dispLon += (curLon - _dispLon) * f;

            bool show = (sim.RouteCoords != null && sim.RouteCoords.Count >= 2) || sim.DrivingRoute || sim.RouteProgress > 0;
            if (show)
                await Exec($"setTruck({_dispLat.ToString("F6", CultureInfo.InvariantCulture)},{_dispLon.ToString("F6", CultureInfo.InvariantCulture)},{(sim.DrivingRoute ? "true" : "false")})");
            else
                await Exec("clearTruck()");
        }

        private async System.Threading.Tasks.Task Exec(string js)
        {
            try { await _web.CoreWebView2.ExecuteScriptAsync(js); } catch { /* page not ready / navigating */ }
        }

        private const string Html = @"<!DOCTYPE html><html><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1.0'>
<link rel='stylesheet' href='https://unpkg.com/leaflet@1.9.4/dist/leaflet.css'/>
<script src='https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'></script>
<style>html,body,#map{height:100%;margin:0;background:#0C0E13}.leaflet-container{background:#0C0E13}</style>
</head><body><div id='map'></div>
<script>
var map=L.map('map',{zoomControl:false,attributionControl:false}).setView([37.7869,-121.9777],6);
L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',{maxZoom:19,subdomains:'abcd'}).addTo(map);
var poly=null, marker=null, glow=null;
function setRoute(c){ if(poly){map.removeLayer(poly);poly=null;} if(c&&c.length>1){ poly=L.polyline(c,{color:'#6FD3FF',weight:5,opacity:0.95}).addTo(map); map.fitBounds(poly.getBounds(),{padding:[34,34]}); } }
function setTruck(lat,lon,follow){ var ll=[lat,lon]; if(!marker){ glow=L.circleMarker(ll,{radius:13,stroke:false,fillColor:'#E2122B',fillOpacity:0.35}).addTo(map); marker=L.circleMarker(ll,{radius:7,color:'#fff',weight:2,fillColor:'#E2122B',fillOpacity:1}).addTo(map);} else { marker.setLatLng(ll); glow.setLatLng(ll);} if(follow){ map.panTo(ll,{animate:false}); } }
function clearTruck(){ if(marker){map.removeLayer(marker);marker=null;} if(glow){map.removeLayer(glow);glow=null;} }
</script></body></html>";
    }
}
