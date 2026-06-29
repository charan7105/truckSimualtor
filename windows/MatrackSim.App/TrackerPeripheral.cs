using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using MatrackSim.Core;

namespace MatrackSim.App
{
    // The simulator core: a BLE peripheral that impersonates a legacy Matrack "MT" tracker,
    // exposed as an INotifyPropertyChanged object so the WPF control panel can drive + observe it.
    //
    // PLATFORM NOTE (read me): Windows BLE advertising broadcasts the *machine name* — there is no
    // per-app local-name API like CoreBluetooth's CBAdvertisementDataLocalNameKey. The ELD app
    // filters peripherals by a name that starts with "ELD-MA", so on Windows the PC MUST be renamed
    // to begin with "ELD-MA" (Settings ▸ System ▸ About ▸ Rename this PC), exactly the same workaround
    // as the macOS name fix. advertisedName below is kept only for the UI/status text.

    /// <summary>Power-on state machine for the cinematic ignition sequence.</summary>
    public enum ClusterPhase { Cold, Igniting, Sweep, Settle, Live }

    /// <summary>
    /// Semantic status color. Swift used SwiftUI's Theme.Color (a UI type); on Windows the color is a
    /// view concern, so the controller exposes the *meaning* and the WPF layer maps it to a brush.
    /// </summary>
    public enum StatusColor { Dim, Red, Green, Amber }

    public sealed class LogLine
    {
        public enum Kind { Out, Inbound, Info, Drop }
        public Guid Id { get; } = Guid.NewGuid();
        public string Time { get; }
        public string Text { get; }
        public Kind LineKind { get; }

        public LogLine(string time, string text, Kind kind)
        {
            Time = time;
            Text = text;
            LineKind = kind;
        }

        // Presentation helpers for the packet-stream DataTemplate (mirrors the symbol/colour the
        // Swift console drew per line). Brushes are frozen so they're safe to read from any thread.
        public string Symbol
        {
            get
            {
                switch (LineKind)
                {
                    case Kind.Out: return "→";
                    case Kind.Inbound: return "←";
                    case Kind.Drop: return "⨯";
                    default: return "•";
                }
            }
        }

        /// <summary>Row text colour — info lines are dimmed like the Mac (kind==.info ? dim : text).</summary>
        public System.Windows.Media.Brush TextBrush =>
            LineKind == Kind.Info ? ThemeBrushes.Dim : ThemeBrushes.Text;

        public System.Windows.Media.Brush Color
        {
            get
            {
                switch (LineKind)
                {
                    case Kind.Out: return ThemeBrushes.Green;
                    case Kind.Inbound: return ThemeBrushes.Ice;
                    case Kind.Drop: return ThemeBrushes.Red;
                    default: return ThemeBrushes.Dim;
                }
            }
        }
    }

    /// <summary>Frozen theme brushes (hex mirrors App.xaml) — safe to share across threads.</summary>
    internal static class ThemeBrushes
    {
        private static System.Windows.Media.SolidColorBrush Make(string hex)
        {
            var c = (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex);
            var b = new System.Windows.Media.SolidColorBrush(c);
            b.Freeze();
            return b;
        }
        public static readonly System.Windows.Media.Brush Text  = Make("#FFE8EDF4");
        public static readonly System.Windows.Media.Brush Dim   = Make("#FF8A93A6");
        public static readonly System.Windows.Media.Brush Ice   = Make("#FF5AC8FA");
        public static readonly System.Windows.Media.Brush Blue  = Make("#FF4A8BFF");
        public static readonly System.Windows.Media.Brush Green = Make("#FF34C759");
        public static readonly System.Windows.Media.Brush Amber = Make("#FFFFB020");
        public static readonly System.Windows.Media.Brush Red   = Make("#FFFF3B30");
    }

    public sealed partial class TrackerPeripheral : INotifyPropertyChanged
    {
        // Swift used a shared static RNG via Double.random/Int.random; mirror with one shared Random.
        private static readonly Random Rng = new Random();
        private static double RandRange(double a, double b) => Rng.NextDouble() * (b - a) + a;
        private static int RandInt(int a, int b) => Rng.Next(a, b + 1);   // inclusive, like Swift Int.random(in: a...b)

        // ---- INotifyPropertyChanged plumbing -------------------------------------------------
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise([CallerMemberName] string name = null) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        private bool Set<T>(ref T field, T value, [CallerMemberName] string name = null)
        {
            if (EqualityComparer<T>.Default.Equals(field, value)) return false;
            field = value;
            Raise(name);
            return true;
        }

        // MARK: - Connection / status
        private string _status = "Starting…";
        public string Status { get => _status; set => Set(ref _status, value); }

        private StatusColor _statusColor = StatusColor.Dim;
        public StatusColor StatusColorValue { get => _statusColor; set => Set(ref _statusColor, value); }

        private bool _connected;
        public bool Connected { get => _connected; set => Set(ref _connected, value); }

        private bool _streaming;
        public bool Streaming { get => _streaming; set => Set(ref _streaming, value); }

        private bool _linkDown;   // F1: emulated out-of-range (we go silent; the app times out)
        public bool LinkDown { get => _linkDown; set => Set(ref _linkDown, value); }

        private DateTime? _dropEndsAt;   // F1: when the outage auto-recovers (for the UI countdown)
        public DateTime? DropEndsAt { get => _dropEndsAt; set => Set(ref _dropEndsAt, value); }

        private ClusterPhase _phase = ClusterPhase.Cold;   // ignition power-on state
        public ClusterPhase Phase { get => _phase; set => Set(ref _phase, value); }

        // MARK: - Live telemetry (mirrored from EngineState each tick)
        private bool _ignitionOn;
        public bool IgnitionOn { get => _ignitionOn; set => Set(ref _ignitionOn, value); }

        private bool _autoDrive;
        public bool AutoDrive { get => _autoDrive; set => Set(ref _autoDrive, value); }

        private bool _autoSignal = true;
        public bool AutoSignal { get => _autoSignal; set => Set(ref _autoSignal, value); }

        private double _speedMph;
        public double SpeedMph { get => _speedMph; set => Set(ref _speedMph, value); }

        private int _rpm;
        public int Rpm { get => _rpm; set => Set(ref _rpm, value); }

        private double _odometerMiles = 25_000.0;
        public double OdometerMiles { get => _odometerMiles; set => Set(ref _odometerMiles, value); }

        private double _engineHours = 4_352.5;
        public double EngineHours { get => _engineHours; set => Set(ref _engineHours, value); }

        private double _fuelPct = 78.0;
        public double FuelPct { get => _fuelPct; set => Set(ref _fuelPct, value); }

        private double _fuel2Pct = 60.0;
        public double Fuel2Pct { get => _fuel2Pct; set => Set(ref _fuel2Pct, value); }

        private int _satellites = 11;
        public int Satellites { get => _satellites; set => Set(ref _satellites, value); }

        private int _headingDeg = 103;
        public int HeadingDeg { get => _headingDeg; set => Set(ref _headingDeg, value); }

        private bool _ecmActive = true;
        public bool EcmActive { get => _ecmActive; set => Set(ref _ecmActive, value); }

        // Read directly by the map's render loop — deliberately NOT observable so position updates
        // don't re-render the whole dashboard every tick (which starved the map and caused stutter).
        public double CurrentLat = 37.78687;
        public double CurrentLon = -121.977687;

        // MARK: - Identity / diagnostics
        private string _vin = "";
        public string Vin   // editable; flows into the LV/VIN packet
        {
            get => _vin;
            set { if (Set(ref _vin, value)) device.Vin = value; }
        }

        private string _firmware = "";
        public string Firmware { get => _firmware; set => Set(ref _firmware, value); }

        private List<string> _faults = new List<string>();
        public List<string> Faults { get => _faults; set => Set(ref _faults, value); }

        // Observable log so the WPF list can bind directly. push() mutates this on the sim thread;
        // the UI is expected to marshal collection changes onto its dispatcher.
        public ObservableCollection<LogLine> Log { get; } = new ObservableCollection<LogLine>();

        // MARK: - Config (everything tunable)
        private SimConfig _config = SimConfig.Default;
        public SimConfig Config { get => _config; set => Set(ref _config, value); }

        // MARK: - Route driving
        private bool _drivingRoute;
        public bool DrivingRoute { get => _drivingRoute; set => Set(ref _drivingRoute, value); }

        private bool _dayDriving;   // F3: DRIVE MY DAY (distinct from a plain ROUTE drive)
        public bool DayDriving { get => _dayDriving; set => Set(ref _dayDriving, value); }

        private string _routeInfo = "";
        public string RouteInfo { get => _routeInfo; set => Set(ref _routeInfo, value); }

        private double _routeProgress;
        public double RouteProgress { get => _routeProgress; set => Set(ref _routeProgress, value); }

        private List<Coordinate> _routeCoords = new List<Coordinate>();
        public List<Coordinate> RouteCoords { get => _routeCoords; set => Set(ref _routeCoords, value); }

        private bool _routeBusy;
        public bool RouteBusy { get => _routeBusy; set => Set(ref _routeBusy, value); }

        private string _routeFrom = "";
        public string RouteFrom { get => _routeFrom; set => Set(ref _routeFrom, value); }

        private string _routeTo = "";
        public string RouteTo { get => _routeTo; set => Set(ref _routeTo, value); }

        private int _routeVersion;   // bumps only when a new route is loaded (drives map redraw)
        public int RouteVersion { get => _routeVersion; set => Set(ref _routeVersion, value); }

        public RouteEngine Route { get; } = new RouteEngine();

        public string AdvertisedName => Config.AdvertisedName;

        // MARK: - BLE peripheral (WinRT GATT) + private sim state
        private GattServiceProvider serviceProvider;          // CBPeripheralManager → GattServiceProvider
        private GattLocalCharacteristic dataChar;             // notify (7add0003)
        private GattLocalCharacteristic commandChar;          // write  (7add0002)
        private readonly EngineState engine = new EngineState();
        private DeviceInfo device = new DeviceInfo();
        private Timer tick;
        private readonly object tickGate = new object();
        private readonly List<byte[]> pending = new List<byte[]>();
        private bool? lastIgnitionSent;
        private string heldPacket;                 // for out-of-order injection
        private DateTime lastWatchdog = DateTime.UtcNow;   // app sends $wdg every ~20s; a real tracker stops streaming if it stops
        private readonly double bootOdometerMiles = SimConfig.Default.StartOdometerMiles;   // for trip distance
        private const double uiTickSec = 0.2;                // smooth sim/UI clock (decoupled from packet cadence)
        private double sinceLastPacket;
        private double autoSpeedCountdown;          // AUTO: seconds until the next random target-speed change
        private double autoSignalCountdown;         // AUTO SIGNAL: seconds until the next random signal-strength change
        private double autoSignalDipCountdown = RandRange(300, 600);   // AUTO SIGNAL: seconds until the next out-of-range dip (dead zone)
        private Timer dropTimer;                    // F1: out-of-range outage timer
        private double nextViolationAtMeters;       // F3: distance-triggered violation scheduler
        private double violationHoldSec;            // F3: remaining seconds of the active violation
        private bool violationIsIdle;               // F3: alternate speeding ↔ idle

        // BLE bookkeeping: WinRT reports connected centrals via SubscribedClients, not a single bool.
        private int subscriberCount;

        public TrackerPeripheral()
        {
            ApplyConfigToEngine();
            Vin = device.Vin;
            Firmware = $"{device.McuFW} · BLE {device.BleFW}";
            InitPresentation();      // wire derived UI bindings + start the refresh timer (see partial)
            StartBLE();              // begin advertising the tracker service on launch (like the macOS app)
        }

        public void StartBLE()
        {
            if (serviceProvider != null) return;
            // WinRT GATT setup is async; fire-and-forget like Swift's CBPeripheralManager init (which
            // also completes asynchronously via peripheralManagerDidUpdateState).
            _ = SetupBLEAsync();
        }

        // MARK: - Cluster-derived display helpers (computed from existing state)
        public int AmbientTempC => 22;
        public double TripMiles => Math.Max(0, OdometerMiles - bootOdometerMiles);
        public double RouteRemainingMeters => Math.Max(0, Route.TotalMeters * (1 - RouteProgress));
        public int RouteMilesLeft => (int)Math.Round(Route.TotalMiles * (1 - RouteProgress), MidpointRounding.AwayFromZero);
        public bool HasRoute => RouteCoords.Count >= 2;
        public string Gear => !IgnitionOn ? "P" : (SpeedMph > 0.5 ? "D" : "N");
        public string Cardinal
        {
            get
            {
                var dirs = new[] { "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
                int i = (int)Math.Floor((HeadingDeg + 22.5) / 45);
                return dirs[((i % 8) + 8) % 8];
            }
        }

        /// <summary>Next-turn icon + signed bearing delta, from a look-ahead along the route.</summary>
        public (string Icon, int DeltaDeg) NextTurn
        {
            get
            {
                if (!Route.HasRoute) return ("location.slash", 0);
                double t = Route.TraveledMeters;
                int h1 = Route.PositionAt(t).HeadingDeg;
                int h2 = Route.PositionAt(Math.Min(Route.TotalMeters, t + 400)).HeadingDeg;
                int d = h2 - h1;
                while (d > 180) d -= 360;
                while (d < -180) d += 360;
                string icon;
                if (Math.Abs(d) > 150) icon = "arrow.uturn.up";
                else if (d > 25) icon = "arrow.turn.up.right";
                else if (d < -25) icon = "arrow.turn.up.left";
                else icon = "arrow.up";
                return (icon, d);
            }
        }

        // MARK: - Ignition power-on sequence (visual only; BLE keeps running)
        // Swift used SwiftUI withAnimation + Task.sleep for the cinematic timing. On WPF the animation
        // is a view concern; we keep the same phase progression + timings via async delays.
        public void BeginStartup()
        {
            if (Phase != ClusterPhase.Cold) return;
            SetEngine(true);                                  // real telemetry spins up "under the curtain"
            Phase = ClusterPhase.Igniting;
            _ = Task.Run(async () =>
            {
                await Task.Delay(350);
                Phase = ClusterPhase.Sweep;
                await Task.Delay(1500);
                Phase = ClusterPhase.Settle;
                await Task.Delay(900);
                Phase = ClusterPhase.Live;
            });
        }
        public void SkipStartup() { Phase = ClusterPhase.Live; }
        public void RearmStartup() { Phase = ClusterPhase.Cold; }

        private void ApplyConfigToEngine()
        {
            engine.OdometerMiles = Config.StartOdometerMiles;
            engine.EngineHours = Config.StartEngineHours;
            engine.FuelLevelPct = Config.StartFuelPct;
            engine.IdleRpmConfig = Config.IdleRpm;
            engine.RpmPerMphConfig = Config.RpmPerMph;
            engine.FuelBurnPctPerMile = Config.FuelBurnPctPerMile;
            Mirror();
        }

        // MARK: - Manual controls
        public void SetEngine(bool on)
        {
            if (runningScenario != null) StopScenario();
            AutoDrive = false; DrivingRoute = false; DayDriving = false;
            engine.IgnitionOn = on;
            if (!on) engine.SpeedMph = 0;
            EnsureClock(); Mirror(); Info("engine " + (on ? "ON" : "OFF"));
        }

        public void SetSpeed(double mph)
        {
            if (runningScenario != null) StopScenario();
            DayDriving = false;                          // a manual speed set ends DRIVE MY DAY automation
            if (DrivingRoute)
            {
                if (mph <= 0) { StopRouteDrive(); return; }   // STOP pauses (keeps position)
                AutoDrive = false;                            // manual speed override; keep driving
                Config.TargetSpeedMph = mph; EnsureClock(); return;
            }
            AutoDrive = false;
            if (mph > 0) engine.IgnitionOn = true;
            engine.SpeedMph = mph;
            EnsureClock(); Mirror();
        }

        /// <summary>
        /// AUTO = automatic (cruise) speed control. It does NOT reset position or load a new route —
        /// it takes over speed on the *current* drive and gradually settles to a cruising speed.
        /// </summary>
        public void SetAutoDrive(bool on)
        {
            if (runningScenario != null) StopScenario();
            DayDriving = false;                          // AUTO cruise takes over from DRIVE MY DAY automation
            AutoDrive = on;
            if (on)
            {
                engine.IgnitionOn = true;
                autoSpeedCountdown = 0;                                  // pick a fresh auto speed immediately
                if (Route.HasRoute)
                {
                    if (!DrivingRoute) BeginDrive();                    // continue the current route, no reset
                }
                else if (!RouteBusy)                                    // no route yet → grab one (skip if a load is already in flight)
                {
                    _ = Task.Run(async () =>
                    {
                        await LoadRandomRoute();
                        if (!AutoDrive || !Route.HasRoute) return;
                        BeginDrive();
                    });
                }
                EnsureClock();
            }
            else
            {
                Config.TargetSpeedMph = 65;                              // restore a sane manual default after auto
            }
            Mirror();
            Info("auto speed " + (on ? "on" : "off"));
        }

        public void InjectFault(string code)
        {
            if (!device.DtcCodes.Contains(code)) device.DtcCodes.Add(code);
            Faults = new List<string>(device.DtcCodes);
            Info($"fault {code} armed (app sees it on next readdtc)");
        }
        public void ClearFaults() { device.DtcCodes = new List<string>(); Faults = new List<string>(); Info("faults cleared"); }
        public void SetFuel(double pct) { engine.FuelLevelPct = Math.Max(0, Math.Min(100, pct)); Mirror(); }
        public void SetFuel2(double pct) { engine.FuelLevel2Pct = Math.Max(0, Math.Min(100, pct)); Mirror(); }
        public void SendVINNow() { SendReliable(MTPacket.Version(device)); }

        // MARK: - F1: signal strength + out-of-range emulation
        /// <summary>
        /// Signal 100→0. Above 0 it ramps packet loss (weak signal); at 0 it goes out of range (drops the link).
        /// Windows has no TX-power API either, so this is emulated: loss reuses the existing EmitNow() gate, and
        /// "out of range" = going silent so the *app* times out (~75s) → disconnects → auto-reconnects.
        /// </summary>
        private double preDropSignalPct = 100;          // signal level to restore after a transient outage

        /// <summary>
        /// AUTO SIGNAL: self-driving link quality. When on, Step() periodically reassigns a random signal
        /// strength so the link sweeps full↔weak↔poor on its own. A manual preset or DROP turns it off.
        /// </summary>
        public void SetAutoSignal(bool on)
        {
            AutoSignal = on;
            if (on)
            {
                autoSignalCountdown = 0;                                 // pick a fresh auto signal immediately
                autoSignalDipCountdown = RandRange(300, 600);            // schedule the first dead-zone dip
                EnsureClock();
            }
            else
            {
                SetSignal(100);                                         // settle back to full when auto is turned off
            }
            Info(on ? "auto signal on" : "auto signal off");
        }

        public void SetSignal(double pct)
        {
            Config.SignalPct = pct;
            Config.PacketLossPct = Math.Max(0, 100 - pct);        // reuse the EmitNow() loss gate
            if (pct <= 0) { if (!LinkDown) DropLink(Config.RangeOutageSec); }   // idempotent: a slider drag to 0 arms once
            else if (LinkDown) ResumeLink();
        }

        /// <summary>
        /// EMULATED out-of-range: suppress telemetry for `seconds`. We never stop advertising (the app
        /// reconnects by scanning, so it must stay discoverable). After ~75s of silence the app disconnects
        /// and auto-reconnects on its own — exactly the real out-of-range round-trip.
        /// </summary>
        public void DropLink(double seconds)
        {
            preDropSignalPct = Config.SignalPct >= 1 ? Config.SignalPct : 100;   // remember weak level to restore on return
            LinkDown = true;
            Config.SignalPct = 0;
            Status = $"OUT OF RANGE — silent {(int)seconds}s"; StatusColorValue = StatusColor.Red;
            Info($"📵 out of range: telemetry suppressed for {(int)seconds}s (≥80s ⇒ app disconnect+reconnect; <75s ⇒ stall demo)");
            DropEndsAt = DateTime.UtcNow.AddSeconds(Math.Max(1, seconds));
            dropTimer?.Dispose();
            dropTimer = new Timer(_ => ResumeLink(), null, (long)(Math.Max(1, seconds) * 1000), Timeout.Infinite);
        }

        /// <summary>
        /// Immediate FORCED disconnect — exactly what the app sees in the field. We tear down the whole
        /// peripheral session (stop advertising + drop the GattServiceProvider); the connected central drops
        /// within ~1–2s. On return (timer or BACK) we re-advertise and the app auto-reconnects via its scan —
        /// the real out-of-range → back-in-range cycle.
        /// </summary>
        public void ForceDisconnect(double seconds)
        {
            preDropSignalPct = Config.SignalPct >= 1 ? Config.SignalPct : 100;
            LinkDown = true;
            Config.SignalPct = 0;
            Status = "OUT OF RANGE — link dropped"; StatusColorValue = StatusColor.Red;
            Info("⛔️ forced disconnect — BLE link torn down (app sees a real disconnect)");
            DropEndsAt = DateTime.UtcNow.AddSeconds(Math.Max(1, seconds));
            TeardownBLE();
            dropTimer?.Dispose();
            dropTimer = new Timer(_ => ResumeLink(), null, (long)(Math.Max(1, seconds) * 1000), Timeout.Infinite);
        }

        /// <summary>Drop the peripheral session so the central is forced to disconnect immediately.</summary>
        private void TeardownBLE()
        {
            try
            {
                serviceProvider?.StopAdvertising();
            }
            catch { /* provider may already be torn down */ }
            // Detach handlers BEFORE releasing. The central doesn't disconnect instantly (it waits out its BLE
            // supervision timeout), so the about-to-die dataChar would otherwise fire a stale
            // SubscribedClientsChanged(count==0) a few seconds later — which resets LinkDown=false and strands us
            // un-advertised, so a later FULL/BACK never calls ResumeLink(). (macOS nils its manager, so it can't
            // fire stale callbacks — this keeps Windows parity.)
            if (dataChar != null) dataChar.SubscribedClientsChanged -= OnSubscribedClientsChanged;
            if (commandChar != null) commandChar.WriteRequested -= OnWriteRequested;
            // Releasing the GattServiceProvider severs the active connection (CB removeAllServices + nil manager).
            serviceProvider = null;
            dataChar = null; commandChar = null;
            subscriberCount = 0;
            Connected = false; Streaming = false; heldPacket = null; pending.Clear();
        }

        /// <summary>
        /// Back in range: resume. If we forced a disconnect (provider torn down) we re-advertise so the app
        /// reconnects; otherwise just restore the stream/status.
        /// </summary>
        public void ResumeLink()
        {
            dropTimer?.Dispose(); dropTimer = null; DropEndsAt = null;
            LinkDown = false;
            if (Config.SignalPct < 1) Config.SignalPct = preDropSignalPct;    // restore the pre-drop weak level (or 100)
            Config.PacketLossPct = Math.Max(0, 100 - Config.SignalPct);
            if (serviceProvider == null)                                       // forced-disconnect teardown → bring the radio back
            {
                Info("📶 back in range — re-advertising for reconnect");
                StartBLE();                                                    // recreates the peripheral → re-advertises → app rescans & reconnects
            }
            else
            {
                Info("📶 back in range — telemetry resumes");
                if (Connected && Streaming) { Status = "Connected · streaming"; StatusColorValue = StatusColor.Green; }
                else if (Connected) { Status = "iPhone connected"; StatusColorValue = StatusColor.Green; }
            }
        }

        // MARK: - Route driving (from → to)
        public async Task LoadRoute(string from, string to)
        {
            RouteBusy = true;
            try
            {
                // Windows routing: OpenStreetMap (Nominatim geocode + OSRM road route, no API key), with a
                // built-in city table + synthetic-line fallback when offline. Replaces the Mac's MapKit
                // Directions (Core's stub throws NotImplementedOnThisPlatform). See WindowsRouting.
                var pts = await WindowsRouting.RouteAsync(from, to);
                Route.SetRoute(pts);
                RouteCoords = pts;
                DrivingRoute = false;            // freshly planned route returns to overview; press DRIVE to go
                RouteVersion += 1;
                RouteInfo = $"{from} → {to} · {Route.TotalMiles.ToString("F0", CultureInfo.InvariantCulture)} mi";
                RouteProgress = 0;
                Info($"route loaded: {RouteInfo}");
            }
            catch (Exception error)
            {
                Info($"route error: {error.Message}");    // keep prior route shown; surface error in log only
            }
            finally
            {
                RouteBusy = false;
            }
        }

        /// <summary>Pick a random real city pair and load a drivable route between them.</summary>
        public async Task LoadRandomRoute()
        {
            var pairs = new (string, string)[]
            {
                ("Dallas, TX", "Houston, TX"),
                ("Los Angeles, CA", "San Diego, CA"),
                ("Chicago, IL", "Milwaukee, WI"),
                ("Phoenix, AZ", "Tucson, AZ"),
                ("Atlanta, GA", "Macon, GA"),
                ("Denver, CO", "Colorado Springs, CO"),
                ("Seattle, WA", "Portland, OR"),
                ("Miami, FL", "Orlando, FL"),
                ("New York, NY", "Philadelphia, PA"),
                ("San Francisco, CA", "Sacramento, CA"),
            };
            var pick = pairs[Rng.Next(pairs.Length)];
            RouteFrom = pick.Item1; RouteTo = pick.Item2;
            await LoadRoute(pick.Item1, pick.Item2);
        }

        public void StartRouteDrive() { BeginDrive(); }     // DRIVE ROUTE button

        /// <summary>
        /// Start/continue driving the loaded route from the current position (no reset), so toggling
        /// speed/auto/stop never teleports back to the start. Only a finished route restarts.
        /// </summary>
        private void BeginDrive()
        {
            if (!Route.HasRoute) { Info("load a route first"); return; }
            if (runningScenario != null) StopScenario();
            if (Route.ProgressFraction >= 0.999) Route.Reset();   // re-drive a finished route from the start
            DrivingRoute = true;
            engine.IgnitionOn = true;
            RouteProgress = Route.ProgressFraction;
            var p = Route.PositionAt(Route.TraveledMeters);
            engine.Latitude = p.Coord.Latitude; engine.Longitude = p.Coord.Longitude; engine.HeadingDeg = p.HeadingDeg;
            EnsureClock();
            Mirror();
            Info("driving route…");
        }

        public void StopRouteDrive() { DrivingRoute = false; DayDriving = false; engine.SpeedMph = 0; Mirror(); Info("route drive stopped"); }

        // MARK: - F3: DRIVE MY DAY (one-click full-day, state-crossing, with event violations)
        /// <summary>Curated long interstate pairs so the day crosses a state line (IFTA is per-jurisdiction mileage).</summary>
        private readonly (string, string)[] dayRoutes = new (string, string)[]
        {
            ("Dallas, TX", "Oklahoma City, OK"),
            ("Atlanta, GA", "Nashville, TN"),
            ("Phoenix, AZ", "Las Vegas, NV"),
            ("Chicago, IL", "Indianapolis, IN"),
            ("Portland, OR", "Seattle, WA"),
            ("Kansas City, MO", "Omaha, NE"),
        };

        /// <summary>
        /// One click: load a long state-crossing route and drive it end-to-end at 30×, with baked-in
        /// speeding + idle EVENT violations — a full day of IFTA per-jurisdiction mileage in ~10 min.
        /// HONEST LIMIT: the app's 11/14/70h HOS *hour* clocks run on real wall-clock and CANNOT be
        /// compressed — use 1× + a long route for genuine HOS exhaustion. This produces mileage + events.
        /// </summary>
        public async Task DriveMyDay()
        {
            var pick = dayRoutes[Rng.Next(dayRoutes.Length)];
            RouteFrom = pick.Item1; RouteTo = pick.Item2;
            await LoadRoute(pick.Item1, pick.Item2);
            if (!Route.HasRoute) { Info("DRIVE MY DAY: route load failed (check network)"); return; }
            Config.RouteTimeScale = 30;
            AutoDrive = false;                                   // steady cruise → deterministic IFTA mileage
            Config.TargetSpeedMph = Config.DayCruiseMph;
            nextViolationAtMeters = Config.ViolationEveryMiles / 0.000621371;
            violationHoldSec = 0; violationIsIdle = false;
            DayDriving = true;
            BeginDrive();
            Info($"▶ DRIVE MY DAY — {pick.Item1} → {pick.Item2} at 30× with auto speeding/idle events");
        }

        public void StopDay() { DayDriving = false; StopRouteDrive(); }

        /// <summary>
        /// F3 event scheduler — alternates a speeding spike and an idle stop every `violationEveryMiles`,
        /// distance-triggered so it fires identically at any timescale. Holds are real-time so the LP
        /// stream (sampled ~1/s) actually records each event.
        /// </summary>
        private void RunDayViolations(double dt)
        {
            if (violationHoldSec > 0)
            {
                violationHoldSec -= dt;
                if (violationHoldSec <= 0) Config.TargetSpeedMph = Config.DayCruiseMph;   // resume cruise
                return;
            }
            if (!(Route.TraveledMeters >= nextViolationAtMeters)) return;
            int atMi = (int)(Route.TotalMiles * Route.ProgressFraction);
            if (violationIsIdle)
            {
                Config.TargetSpeedMph = 0; violationHoldSec = Config.IdleStopSec;            // idle stop, ignition stays on
                Info($"⚠︎ DRIVE MY DAY: idle stop ~{(int)Config.IdleStopSec}s at {atMi} mi");
            }
            else
            {
                Config.TargetSpeedMph = Config.SpeedingViolationMph; violationHoldSec = 6;   // speeding spike
                Info($"⚠︎ DRIVE MY DAY: speeding {(int)Config.SpeedingViolationMph} mph at {atMi} mi");
            }
            violationIsIdle = !violationIsIdle;
            nextViolationAtMeters += Config.ViolationEveryMiles / 0.000621371;
        }

        // MARK: - Live scenario playback (plays a scenario's exact packet sequence over BLE)
        private Timer scenarioTimer;
        private List<Emitted> scenarioQueue = new List<Emitted>();
        private readonly object scenarioGate = new object();
        private List<Emitted> pendingStored = new List<Emitted>();   // backdated stored packets, dumped on the app's next readstr (post-reconnect)
        private double pendingStoredCadence = 1.0;

        private string _runningScenario;
        public string RunningScenario { get => _runningScenario; set => Set(ref _runningScenario, value); }
        private string runningScenario { get => _runningScenario; set => RunningScenario = value; }

        public void RunScenario(Scenario s)
        {
            AutoDrive = false; DrivingRoute = false; DayDriving = false;   // step() pauses normal emission while a scenario runs
            runningScenario = s.Name;
            // Stored-replay / Unassigned-Driving scenarios must arrive as a real flash dump on RECONNECT:
            // both apps run stored replay (and UDP classification) ONLY right after the readstr they send on
            // reconnect. Replaying inline over the live link is silently ignored (storedEventsProcessed==true).
            if (IsStoredReplay(s))
            {
                var stored = ScenarioRunner.StoredReplay(s, Config);
                Info($"▶ scenario '{s.Name}' — {stored.Count} stored packets queued; dropping the link so the app reconnects & re-requests them");
                ReplayStored(stored, Math.Max(0.05, Config.PacketIntervalSec));
                return;
            }
            scenarioQueue = ScenarioRunner.Run(s, Config);
            Info($"▶ scenario '{s.Name}' — {scenarioQueue.Count} packets (effects baked in)");
            scenarioTimer?.Dispose();
            long period = (long)(Math.Max(0.05, Config.PacketIntervalSec) * 1000);
            scenarioTimer = new Timer(_ => PopScenario(), null, period, period);
        }

        // Scenarios whose expect depends on the app processing STORED packets (replay or Unassigned Driving):
        // they only fire after a genuine disconnect→reconnect→readstr, never from an inline live stream.
        public static bool IsStoredReplay(Scenario s)
        {
            if (s.Id == 12) return true;                                  // Unassigned Driving (UDP)
            return s.Transport.TKind == Transport.TransportKind.Disconnect
                || s.Transport.TKind == Transport.TransportKind.StoredBacklog;
        }

        // Stash backdated stored packets and force a REAL BLE disconnect. When the app reconnects and sends
        // readstr, the handler dumps them + LAST_STORED_PACKET + the true count — the only sequence that makes
        // both apps run stored replay / UDP classification.
        public void ReplayStored(List<Emitted> stored, double cadenceSec, double outageSec = 8)
        {
            if (stored == null || stored.Count == 0) return;
            pendingStored = stored;
            pendingStoredCadence = cadenceSec;
            ForceDisconnect(outageSec);
        }

        public void StopScenario()
        {
            scenarioTimer?.Dispose(); scenarioTimer = null;
            scenarioQueue.Clear(); runningScenario = null; Info("scenario stopped");
        }

        /// <summary>
        /// F2: replay N stored 'S' packets at a configurable cadence to reproduce Harshith's fast-dump
        /// disconnect (≈0.5s breaks the app; 1.0s completes cleanly). The SIM never fails — it reproduces
        /// the STIMULUS for the app to react to. Reuses the scenario playback path with its own cadence timer.
        /// </summary>
        public void DumpStoredPackets(int count, double cadenceSec, bool stopDrive = true)
        {
            if (stopDrive) { AutoDrive = false; DrivingRoute = false; DayDriving = false; }   // app-issued readstr keeps the drive (resumes when queue drains)
            scenarioQueue = ScenarioRunner.StoredDump(count, Config);
            runningScenario = $"Stored dump ({count} @ {(int)(cadenceSec * 1000)}ms)";
            Info($"▶ stored dump — {count} packets @ {(int)(cadenceSec * 1000)}ms cadence (≈500ms repros the disconnect)");
            scenarioTimer?.Dispose();
            long period = (long)(Math.Max(0.05, cadenceSec) * 1000);
            scenarioTimer = new Timer(_ => PopScenario(), null, period, period);
        }

        private void PopScenario()
        {
            lock (scenarioGate)
            {
                if (scenarioQueue.Count == 0)
                {
                    scenarioTimer?.Dispose(); scenarioTimer = null; runningScenario = null;
                    Mirror(); Info("✓ scenario complete"); return;
                }
                var em = scenarioQueue[0];
                scenarioQueue.RemoveAt(0);
                switch (em.ItemKind)
                {
                    case Emitted.Kind.Raw:
                        SendRaw(em.Wire);
                        break;
                    case Emitted.Kind.Malformed:
                        Push(new LogLine(Stamp(), em.Wire + "  [malformed — app should reject]", LogLine.Kind.Drop));
                        Transmit(Encoding.UTF8.GetBytes(em.Wire));                     // sent un-framed; the app validator rejects it
                        break;
                    default:
                        Push(new LogLine(Stamp(), em.Wire, em.ItemKind == Emitted.Kind.Stored ? LogLine.Kind.Info : LogLine.Kind.Out));
                        foreach (var f in MTPacket.Frame(em.Wire)) Queue(f);          // network effects already applied by the runner
                        break;
                }
            }
        }

        // MARK: - Logging
        private static string Stamp() => DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture);
        private void Info(string s) => Push(new LogLine(Stamp(), s, LogLine.Kind.Info));
        private void Push(LogLine l)
        {
            // Log is bound to the WPF ListBox; mutating it off the UI thread throws. The sim ticks on a
            // background Timer, so marshal collection changes onto the dispatcher (see PostToUi in the
            // presentation partial). The console echo below can run on any thread.
            PostToUi(() =>
            {
                Log.Add(l);
                while (Log.Count > 250) Log.RemoveAt(0);
                Raise(nameof(LogCountText));
            });
            string sym = l.LineKind == LogLine.Kind.Out ? "→" :
                         (l.LineKind == LogLine.Kind.Inbound ? "←" :
                         (l.LineKind == LogLine.Kind.Drop ? "⨯" : "•"));
            Console.WriteLine($"[{l.Time}] {sym} {l.Text}");
        }

        /// <summary>
        /// Publish telemetry to the UI, but only the values that actually changed — otherwise the
        /// 5 Hz clock would re-render the whole dashboard (and the map) every tick and lag interaction.
        /// </summary>
        private void Mirror()
        {
            // Position is plain (read by the map loop) — always fresh, no UI publish.
            CurrentLat = engine.Latitude;
            CurrentLon = engine.Longitude;
            // Publish UI values only when the *displayed* value changes, so steady cruise doesn't
            // re-render the dashboard every tick and starve the map's render loop.
            if (SpeedMph != engine.SpeedMph) SpeedMph = engine.SpeedMph;
            if (Rpm != engine.Rpm) Rpm = engine.Rpm;
            if (Math.Round(OdometerMiles) != Math.Round(engine.OdometerMiles)) OdometerMiles = engine.OdometerMiles;
            if (Math.Round(EngineHours * 10) != Math.Round(engine.EngineHours * 10)) EngineHours = engine.EngineHours;
            if (Math.Round(FuelPct) != Math.Round(engine.FuelLevelPct)) FuelPct = engine.FuelLevelPct;
            if (Math.Round(Fuel2Pct) != Math.Round(engine.FuelLevel2Pct)) Fuel2Pct = engine.FuelLevel2Pct;
            if (Satellites != engine.Satellites) Satellites = engine.Satellites;
            if (HeadingDeg != engine.HeadingDeg) HeadingDeg = engine.HeadingDeg;
            if (IgnitionOn != engine.IgnitionOn) IgnitionOn = engine.IgnitionOn;
            if (EcmActive != engine.EcmActive) EcmActive = engine.EcmActive;
        }

        // MARK: - Outbound (raw control replies vs framed data packets) + network effects
        private void SendRaw(string s) { Transmit(Encoding.UTF8.GetBytes(s)); Push(new LogLine(Stamp(), s, LogLine.Kind.Out)); }

        /// <summary>
        /// Command reply / important state packet — always delivered cleanly.
        /// Network effects (loss/dup/out-of-order) apply only to the live telemetry stream,
        /// never to replies the app is actively waiting for.
        /// </summary>
        private void SendReliable(string payload)
        {
            Push(new LogLine(Stamp(), payload, LogLine.Kind.Out));
            foreach (var f in MTPacket.Frame(payload)) Queue(f);
        }

        private void SendPacket(string payload)
        {
            // Out-of-order: hold this one, emit the previously-held first.
            if (RandRange(0, 100) < Config.OutOfOrderPct && heldPacket == null)
            {
                heldPacket = payload;
                Push(new LogLine(Stamp(), $"{payload}  [held: out-of-order]", LogLine.Kind.Drop));
                return;
            }
            EmitNow(payload);
            if (heldPacket != null) { var held = heldPacket; heldPacket = null; EmitNow(held); }
        }

        private void EmitNow(string payload)
        {
            // Packet loss
            if (RandRange(0, 100) < Config.PacketLossPct)
            {
                Push(new LogLine(Stamp(), $"{payload}  [dropped: packet loss]", LogLine.Kind.Drop)); return;
            }
            Push(new LogLine(Stamp(), payload, LogLine.Kind.Out));
            var chunks = MTPacket.Frame(payload);
            Action send = () => { foreach (var c in chunks) Queue(c); };
            if (Config.ExtraDelayMs > 0)
            {
                double d = RandRange(0, Config.ExtraDelayMs) / 1000;
                // Swift: DispatchQueue.main.asyncAfter — defer the send by a random fraction of a tick.
                _ = Task.Run(async () => { await Task.Delay((int)(d * 1000)); send(); });
            }
            else { send(); }
            // Duplicate
            if (RandRange(0, 100) < Config.DuplicatePct)
            {
                Push(new LogLine(Stamp(), $"{payload}  [duplicate]", LogLine.Kind.Out));
                foreach (var c in chunks) Queue(c);
            }
        }

        private void Transmit(byte[] data) { Queue(data); }
        private void Queue(byte[] data) { lock (pending) { pending.Add(data); } Drain(); }

        private void Drain()
        {
            var ch = dataChar;
            if (serviceProvider == null || ch == null) return;
            // WinRT NotifyValueAsync delivers to all subscribed clients (CB updateValue onSubscribedCentrals:nil).
            // It returns immediately; unlike CB there's no boolean "buffer full" back-pressure, so we send each
            // queued frame in order and clear the queue. peripheralManagerIsReady has no WinRT equivalent.
            List<byte[]> toSend;
            lock (pending)
            {
                if (pending.Count == 0) return;
                toSend = new List<byte[]>(pending);
                pending.Clear();
            }
            foreach (var frame in toSend)
            {
                try
                {
                    var writer = new DataWriter();
                    writer.WriteBytes(frame);
                    var buffer = writer.DetachBuffer();
                    _ = ch.NotifyValueAsync(buffer);
                }
                catch { /* central may have dropped mid-send */ }
            }
        }

        // MARK: - Continuous sim clock (runs whether or not the app is connected)
        private void EnsureClock()
        {
            lock (tickGate)
            {
                if (tick != null) return;
                long period = (long)(uiTickSec * 1000);
                tick = new Timer(_ => Step(), null, period, period);
            }
        }

        private void StartStreaming()
        {
            Streaming = true; lastIgnitionSent = null; lastWatchdog = DateTime.UtcNow;
            sinceLastPacket = Config.PacketIntervalSec;          // emit the first live packet promptly
            if (!LinkDown) { Status = "Connected · streaming"; StatusColorValue = StatusColor.Green; }  // don't override OUT OF RANGE
            EnsureClock();
        }

        /// <summary>
        /// One simulation step. Always advances motion + telemetry (so the map moves standalone);
        /// only transmits packets while the app is subscribed.
        /// </summary>
        private void Step()
        {
            if (runningScenario != null) return;        // scenario playback owns the stream
            double dt = uiTickSec;
            if (AutoSignal && !LinkDown)                 // AUTO SIGNAL: sweep link quality like real driving
            {
                autoSignalCountdown -= dt;
                if (autoSignalCountdown <= 0)
                {
                    autoSignalCountdown = RandRange(3, 6);
                    SetSignal(RandInt(20, 100));
                }
                autoSignalDipCountdown -= dt;                 // occasional dead-zone: a real out-of-range dip (tunnel / rural gap)
                if (autoSignalDipCountdown <= 0)
                {
                    autoSignalDipCountdown = RandRange(300, 600);
                    DropLink(Config.RangeOutageSec);
                }
            }
            if (DrivingRoute && Route.HasRoute)
            {
                engine.IgnitionOn = true;
                if (AutoDrive)                                  // AUTO: vary cruise speed like real driving
                {
                    autoSpeedCountdown -= dt;
                    if (autoSpeedCountdown <= 0)
                    {
                        autoSpeedCountdown = RandRange(4, 9);
                        Config.TargetSpeedMph = RandInt(38, 70);
                    }
                }
                double driveDt = dt * Config.RouteTimeScale;        // compress time so the truck visibly crosses the route
                UpdateRouteSpeed(driveDt);
                double metersThisTick = engine.SpeedMph * 0.44704 * driveDt;
                var pos = Route.Advance(metersThisTick);
                if (pos.HasValue)
                {
                    engine.Latitude = pos.Value.Coord.Latitude; engine.Longitude = pos.Value.Coord.Longitude; engine.HeadingDeg = pos.Value.HeadingDeg;
                }
                if (DayDriving) RunDayViolations(dt);       // F3: bake in speeding + idle events along the day
                double pf = Route.ProgressFraction;                  // publish only on whole-% change (avoid 5 Hz churn)
                if ((int)(pf * 100) != (int)(RouteProgress * 100)) RouteProgress = pf;
                engine.Advance(driveDt);
                if (Route.IsComplete || Route.ProgressFraction >= 0.999)
                {
                    engine.SpeedMph = 0; DrivingRoute = false; RouteProgress = 1;
                    if (DayDriving) { DayDriving = false; Info("✓ DRIVE MY DAY complete — full day of IFTA mileage logged"); }
                    Info("route complete — arrived");
                }
            }
            else
            {
                engine.Advance(dt * Config.TimeMultiplier);
            }
            Mirror();

            sinceLastPacket += dt;
            if (Streaming && !LinkDown && sinceLastPacket >= Config.PacketIntervalSec)   // linkDown = out of range → silent
            {
                sinceLastPacket = 0;
                if (lastIgnitionSent != engine.IgnitionOn) { SendReliable(MTPacket.Ignition(engine, engine.IgnitionOn)); lastIgnitionSent = engine.IgnitionOn; }
                SendPacket(MTPacket.LivePosition(engine));
            }
            // Real-tracker watchdog: app sends $wdg every ~20s; if it stops, the tracker stops streaming
            // (resumes on the next readdata). 90s is a safe margin so normal operation never trips it.
            if (Streaming && (DateTime.UtcNow - lastWatchdog).TotalSeconds > 90)
            {
                Streaming = false;
                Status = "Watchdog lost — stream paused"; StatusColorValue = StatusColor.Amber;
                Info("no watchdog ≥90s — a real tracker stops streaming (resumes on readdata)");
            }
        }

        private void UpdateRouteSpeed(double dt)
        {
            double target = Config.TargetSpeedMph;
            double remaining = Route.TotalMeters - Route.TraveledMeters;
            double v = engine.SpeedMph * 0.44704;
            double brakeM = (v * v) / (2 * Math.Max(0.2, Config.DecelMphPerSec * 0.44704));
            double stepM = v * dt;                                       // distance covered this (compressed) tick
            if (remaining <= brakeM + stepM + 8)                         // begin braking ≥1 tick early so we don't blow past the stop
            {
                engine.SpeedMph = Math.Max(0, engine.SpeedMph - Config.DecelMphPerSec * dt);
            }
            else if (engine.SpeedMph < target)
            {
                engine.SpeedMph = Math.Min(target, engine.SpeedMph + Config.AccelMphPerSec * dt);
            }
            else if (engine.SpeedMph > target)
            {
                engine.SpeedMph = Math.Max(target, engine.SpeedMph - Config.DecelMphPerSec * dt);
            }
        }

        // MARK: - Command responder (mirrors real MT firmware)
        private void HandleTrackerCommand(string raw)
        {
            string c = raw.ToLowerInvariant();
            if (LinkDown) return;   // OUT OF RANGE: total silence — don't answer commands either, so the app times out and disconnects
            if (c.StartsWith("readdata"))
            {
                SendRaw("ACK,DATA");
                SendReliable(MTPacket.Version(device)); SendReliable(MTPacket.Version(device));   // ≥2 LV so app learns VIN/firmware
                StartStreaming();
            }
            else if (c.StartsWith("readvin")) { SendReliable(MTPacket.Version(device)); }
            else if (c.StartsWith("readstr"))
            {
                // The app sends readstr automatically after every connect, resetting its
                // storedEventsProcessed flag to false right before it — so THIS is the moment to deliver a
                // backlog. If a stored-replay/UDP scenario armed one (ReplayStored → ForceDisconnect), dump
                // it now so the app actually runs replay/UDP classification. Otherwise reply empty.
                if (pendingStored.Count > 0)
                {
                    int n = pendingStored.Count;
                    var q = new List<Emitted>(pendingStored);
                    q.Add(new Emitted("LAST_STORED_PACKET", Emitted.Kind.Raw));
                    q.Add(new Emitted("SAVED PACKET COUNT:" + n.ToString(CultureInfo.InvariantCulture), Emitted.Kind.Raw));
                    pendingStored = new List<Emitted>();
                    scenarioQueue = q;
                    runningScenario = $"Stored replay ({n})";
                    scenarioTimer?.Dispose();
                    long period = (long)(Math.Max(0.05, pendingStoredCadence) * 1000);
                    scenarioTimer = new Timer(_ => PopScenario(), null, period, period);
                    Info($"▶ app reconnected & sent readstr → dumping {n} stored packets (replay/UDP fires now)");
                }
                else
                {
                    SendRaw("LAST_STORED_PACKET"); SendRaw("SAVED PACKET COUNT:0");
                }
            }
            else if (c.StartsWith("readdtc")) { SendReliable(MTPacket.Dtc(device.DtcCodes, engine.IgnitionOn ? 1 : 0, engine.Rpm)); }
            else if (c.StartsWith("clrdtc")) { device.DtcCodes = new List<string>(); Faults = new List<string>(); }
            else if (c.StartsWith("stopdata")) { SendRaw("ACK,STOP"); }
            else if (c.StartsWith("$wdg") || c.StartsWith("wdg")) { lastWatchdog = DateTime.UtcNow; }   // keepalive: consume like a real tracker (no reply)
        }

        // MARK: - WinRT GATT peripheral (CBPeripheralManagerDelegate equivalent)
        private async Task SetupBLEAsync()
        {
            try
            {
                var serviceUuid = Guid.Parse("7add0001-f286-4c78-adda-520c4ba3500c");
                var result = await GattServiceProvider.CreateAsync(serviceUuid);
                if (result.Error != BluetoothError.Success)
                {
                    Status = "Bluetooth error"; StatusColorValue = StatusColor.Red;
                    Info($"failed to create GATT service: {result.Error}");
                    return;
                }
                var provider = result.ServiceProvider;

                // Write characteristic (7add0002): Write | WriteWithoutResponse
                var writeParams = new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.Write | GattCharacteristicProperties.WriteWithoutResponse,
                    WriteProtectionLevel = GattProtectionLevel.Plain,
                };
                var writeRes = await provider.Service.CreateCharacteristicAsync(
                    Guid.Parse("7add0002-f286-4c78-adda-520c4ba3500c"), writeParams);
                if (writeRes.Error != BluetoothError.Success)
                {
                    Status = "Bluetooth error"; StatusColorValue = StatusColor.Red;
                    Info($"failed to add command characteristic: {writeRes.Error}");
                    return;
                }
                commandChar = writeRes.Characteristic;
                commandChar.WriteRequested += OnWriteRequested;

                // Notify characteristic (7add0003): Notify
                var notifyParams = new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.Notify,
                    ReadProtectionLevel = GattProtectionLevel.Plain,
                };
                var notifyRes = await provider.Service.CreateCharacteristicAsync(
                    Guid.Parse("7add0003-f286-4c78-adda-520c4ba3500c"), notifyParams);
                if (notifyRes.Error != BluetoothError.Success)
                {
                    Status = "Bluetooth error"; StatusColorValue = StatusColor.Red;
                    Info($"failed to add data characteristic: {notifyRes.Error}");
                    return;
                }
                dataChar = notifyRes.Characteristic;
                dataChar.SubscribedClientsChanged += OnSubscribedClientsChanged;

                serviceProvider = provider;

                // Advertise. NOTE: Windows broadcasts the machine NAME — there is no per-app local-name API.
                // The PC must be renamed to start with "ELD-MA" for the ELD app to find it (see header comment).
                provider.StartAdvertising(new GattServiceProviderAdvertisingParameters
                {
                    IsConnectable = true,
                    IsDiscoverable = true,
                });

                EnsureClock();
                Status = $"Advertising as {AdvertisedName}"; StatusColorValue = StatusColor.Amber;
                Info("Bluetooth on — publishing tracker service");
                Info($"advertising as \"{AdvertisedName}\" — waiting for the ELD app");
                Info("Windows advertises the PC NAME — rename this PC to start with \"ELD-MA\" so the ELD app can find it");
            }
            catch (Exception ex)
            {
                Status = "Bluetooth error"; StatusColorValue = StatusColor.Red;
                Info($"BLE setup failed: {ex.Message}");
            }
        }

        // didReceiveWrite → handle each write request (read value, log inbound, handle command, respond).
        private void OnWriteRequested(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
        {
            _ = HandleWriteAsync(args);
        }

        private async Task HandleWriteAsync(GattWriteRequestedEventArgs args)
        {
            using (var deferral = args.GetDeferral())
            {
                var request = await args.GetRequestAsync();
                if (request == null) { return; }
                try
                {
                    var reader = DataReader.FromBuffer(request.Value);
                    byte[] bytes = new byte[request.Value.Length];
                    reader.ReadBytes(bytes);
                    string s = Encoding.UTF8.GetString(bytes);
                    Push(new LogLine(Stamp(), s, LogLine.Kind.Inbound));
                    HandleTrackerCommand(s);
                }
                catch { /* undecodable write — ignore like CB does on nil string */ }
                // respond like CB p.respond(to:withResult:.success). WriteWithoutResponse requests don't expect one.
                if (request.Option == GattWriteOption.WriteWithResponse)
                {
                    request.Respond();
                }
            }
        }

        // didSubscribeTo / didUnsubscribeFrom → track connection via subscribed-client count.
        private void OnSubscribedClientsChanged(GattLocalCharacteristic sender, object args)
        {
            int count = sender.SubscribedClients.Count;
            int prev = subscriberCount;
            subscriberCount = count;
            if (count > prev)   // a central subscribed to the data characteristic
            {
                Connected = true; Status = "iPhone connected"; StatusColorValue = StatusColor.Green;
                Info("✓ iPhone subscribed to data characteristic");
            }
            else if (count == 0)   // last central unsubscribed → disconnected
            {
                Connected = false; Streaming = false; heldPacket = null; pending.Clear();   // drop stale out-of-order hold + unsent chunks
                if (runningScenario != null) StopScenario();             // a disconnect mid-dump clears it so live streaming resumes on reconnect
                dropTimer?.Dispose(); dropTimer = null; LinkDown = false; DropEndsAt = null;   // out-of-range ends when the link actually drops → reconnect resumes streaming
                Status = $"Advertising as {AdvertisedName}"; StatusColorValue = StatusColor.Amber;
                Info("iPhone disconnected");
            }
        }
    }
}
