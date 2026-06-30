using System;
using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace MatrackSim.App
{
    /// <summary>
    /// Tiny LAN position broadcaster — the Windows mirror of SimBridge.swift. A phone on the SAME network
    /// (shared WiFi, or — easiest — the phone's own hotspot with this PC joined to it) can follow the drive:
    /// the Matrack Fuel App's "Link to sim" polls GET /pos and copies the position into its location, so US
    /// fuel stations appear around the moving truck even for testers physically in India.
    ///
    /// Protocol: HTTP, port 8723.  GET /pos → {"lat":..,"lon":..,"hdg":..,"spd":..,"route":"..","ts":..}
    /// Uses a raw TcpListener so it needs no admin / netsh URL-ACL.
    /// </summary>
    public sealed class SimBridge : INotifyPropertyChanged
    {
        public static readonly SimBridge Shared = new SimBridge();
        public const int Port = 8723;

        /// <summary>Supplied by the app — the live truck position to serve.</summary>
        public Func<(double lat, double lon, int hdg, double spd, string route)> Position = () => (0, 0, 0, 0, "");

        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise([CallerMemberName] string n = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

        private string _linkIP = "—";
        public string LinkIP { get => _linkIP; private set { _linkIP = value; Raise(); Raise(nameof(LinkText)); } }

        private bool _running;
        public bool Running { get => _running; private set { _running = value; Raise(); Raise(nameof(LinkText)); } }

        public string LinkText => Running ? $"FUEL LINK {LinkIP}:{Port}" : "";

        private TcpListener _listener;

        public void Start()
        {
            if (_listener != null) return;
            try
            {
                _listener = new TcpListener(IPAddress.Any, Port);
                _listener.Start();
                LinkIP = LocalIPv4() ?? "—";
                Running = true;
                _ = AcceptLoop();
            }
            catch { Running = false; _listener = null; }
        }

        private async Task AcceptLoop()
        {
            while (_listener != null)
            {
                TcpClient client;
                try { client = await _listener.AcceptTcpClientAsync(); }
                catch { break; }
                _ = Serve(client);   // one connection at a time is plenty for a 1 Hz poll
            }
        }

        private async Task Serve(TcpClient client)
        {
            try
            {
                using (client)
                {
                    var stream = client.GetStream();
                    var buf = new byte[2048];
                    try { await stream.ReadAsync(buf, 0, buf.Length); } catch { /* ignore request body */ }

                    var p = Position();
                    string body = $"{{\"lat\":{p.lat.ToString(System.Globalization.CultureInfo.InvariantCulture)}," +
                                  $"\"lon\":{p.lon.ToString(System.Globalization.CultureInfo.InvariantCulture)}," +
                                  $"\"hdg\":{p.hdg}," +
                                  $"\"spd\":{p.spd.ToString(System.Globalization.CultureInfo.InvariantCulture)}," +
                                  $"\"route\":\"{p.route}\",\"ts\":{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}}}";
                    string resp = "HTTP/1.1 200 OK\r\n" +
                                  "Content-Type: application/json\r\n" +
                                  "Access-Control-Allow-Origin: *\r\n" +
                                  "Connection: close\r\n" +
                                  $"Content-Length: {Encoding.UTF8.GetByteCount(body)}\r\n\r\n" + body;
                    var bytes = Encoding.UTF8.GetBytes(resp);
                    await stream.WriteAsync(bytes, 0, bytes.Length);
                }
            }
            catch { /* client vanished */ }
        }

        /// <summary>This PC's LAN IPv4 (Wi-Fi / Ethernet / hotspot), skipping loopback + virtual adapters.</summary>
        private static string LocalIPv4()
        {
            string best = null;
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    string ip = ua.Address.ToString();
                    if (ip.StartsWith("169.254")) continue;   // skip APIPA
                    var t = ni.NetworkInterfaceType;
                    if (t == NetworkInterfaceType.Wireless80211 || t == NetworkInterfaceType.Ethernet) return ip;
                    best ??= ip;
                }
            }
            return best;
        }
    }
}
