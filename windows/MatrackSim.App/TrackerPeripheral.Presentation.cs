using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows.Media;
using System.Windows.Threading;
using MatrackSim.Core;

namespace MatrackSim.App
{
    // Presentation/view-model surface for the WPF operator panel. The verified BLE + sim engine lives in
    // TrackerPeripheral.cs; this partial only adds the *display* adapters (formatted text, theme brushes,
    // speed display in mph, the scenario picker) and the two-way slider/toggle plumbing the XAML binds to.
    // Nothing here touches the wire protocol — it mirrors what ControlsDrawer.swift presented on macOS.
    public sealed partial class TrackerPeripheral
    {
        private DispatcherTimer _uiTimer;

        /// <summary>Called from the constructor: subscribe derived bindings + start the UI refresh timer.</summary>
        private void InitPresentation()
        {
            PropertyChanged += OnSelfChanged;

            // A light UI clock keeps the time-based read-outs (outage countdown, signal, log count) live
            // even when no underlying property happens to change. Only created when a Dispatcher exists.
            var disp = System.Windows.Application.Current?.Dispatcher;
            if (disp != null)
            {
                _uiTimer = new DispatcherTimer(DispatcherPriority.Background, disp)
                {
                    Interval = TimeSpan.FromMilliseconds(250),
                };
                _uiTimer.Tick += (s, e) =>
                {
                    Raise(nameof(OutageCountdown));
                    Raise(nameof(SignalState));
                    Raise(nameof(SignalColor));
                    Raise(nameof(SignalBrush));
                    Raise(nameof(LogCountText));
                    RaiseActiveStates();
                    string now = DateTime.Now.ToString("HH:mm", CultureInfo.InvariantCulture);
                    if (now != _clockText) { _clockText = now; Raise(nameof(ClockText)); }
                };
                _uiTimer.Start();
            }
        }

        private void RaiseActiveStates()
        {
            Raise(nameof(ActiveSpeedStop)); Raise(nameof(ActiveSpeed35)); Raise(nameof(ActiveSpeed55)); Raise(nameof(ActiveSpeed70));
            Raise(nameof(ActiveT1)); Raise(nameof(ActiveT5)); Raise(nameof(ActiveT10)); Raise(nameof(ActiveT25)); Raise(nameof(ActiveT30));
            Raise(nameof(ActiveSigFull)); Raise(nameof(ActiveSigAuto)); Raise(nameof(ActiveSigPoor));
            Raise(nameof(SignalSlider)); Raise(nameof(SignalDbmLabel)); Raise(nameof(SignalSliderLabel));
        }

        /// <summary>Run an action on the UI thread (or inline if already there / no app present).</summary>
        private void PostToUi(Action a)
        {
            var disp = System.Windows.Application.Current?.Dispatcher;
            if (disp == null || disp.CheckAccess()) a();
            else disp.BeginInvoke(a);
        }

        // Re-publish derived properties whenever their underlying source property changes. Derived names
        // aren't handled here, so this never recurses infinitely.
        private void OnSelfChanged(object sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            switch (e.PropertyName)
            {
                case nameof(SpeedMph):
                    Raise(nameof(SpeedSliderMph)); Raise(nameof(SpeedMphText)); Raise(nameof(ModeText)); Raise(nameof(ModeBrush));
                    Raise(nameof(SpeedFraction)); Raise(nameof(SpeedCenterText)); Raise(nameof(GearValue));
                    break;
                case nameof(Rpm):
                    Raise(nameof(TachFraction)); Raise(nameof(RpmText)); Raise(nameof(TachHot));
                    break;
                case nameof(Status):
                    Raise(nameof(ConnectionStatus));
                    break;
                case nameof(StatusColorValue):
                    Raise(nameof(StatusBrush));
                    break;
                case nameof(Connected):
                case nameof(Streaming):
                case nameof(IgnitionOn):
                case nameof(AutoDrive):
                case nameof(DrivingRoute):
                case nameof(DayDriving):
                case nameof(RunningDump):
                    Raise(nameof(ModeText)); Raise(nameof(ModeBrush)); Raise(nameof(IsDumping)); Raise(nameof(FooterStatusText));
                    Raise(nameof(GearValue));
                    Raise(nameof(SetupHint));   // TEST SETUP hint flips with the connection
                    break;
                case nameof(LinkDown):
                case nameof(DropEndsAt):
                    Raise(nameof(SignalState)); Raise(nameof(SignalColor)); Raise(nameof(SignalBrush)); Raise(nameof(OutageCountdown));
                    Raise(nameof(LinkDownVisible)); Raise(nameof(PacketLossPct)); Raise(nameof(PacketLossText));
                    break;
                case nameof(Faults):
                    Raise(nameof(FaultsText)); Raise(nameof(FaultsEmpty));
                    Raise(nameof(FaultP0143)); Raise(nameof(FaultP0217)); Raise(nameof(FaultC0035)); Raise(nameof(FaultU0101));
                    Raise(nameof(DtcButtonBrush)); Raise(nameof(DtcButtonText));
                    break;
                case nameof(Phase):
                    Raise(nameof(IgnitionVisible)); Raise(nameof(IsCold)); Raise(nameof(SweepVisible));
                    Raise(nameof(SweepFraction)); Raise(nameof(SweepSpeedText)); Raise(nameof(SweepRpmText)); Raise(nameof(SystemsNominalVisible));
                    break;
                case nameof(Vin):
                    Raise(nameof(VinDisplay)); Raise(nameof(VinBadge)); Raise(nameof(VinBadgeBrush));
                    break;
                case nameof(OdometerMiles): Raise(nameof(OdometerText)); Raise(nameof(TripText)); Raise(nameof(OdometerInput)); break;
                case nameof(EngineHours): Raise(nameof(EngineHoursText)); Raise(nameof(EngineHoursInput)); break;
                case nameof(FuelPct): Raise(nameof(FuelTintColor)); Raise(nameof(FuelBrush)); Raise(nameof(FuelPctText)); Raise(nameof(FuelSlider)); break;
                case nameof(Fuel2Pct): Raise(nameof(Fuel2TintColor)); Raise(nameof(Fuel2Brush)); Raise(nameof(Fuel2PctText)); Raise(nameof(Fuel2Slider)); break;
                case nameof(Satellites): Raise(nameof(SatellitesText)); Raise(nameof(SatsBrush)); break;
                case nameof(HeadingDeg): Raise(nameof(HeadingText)); Raise(nameof(Cardinal)); break;
                case nameof(EcmActive): Raise(nameof(EcmText)); Raise(nameof(EcmBrush)); break;
                case nameof(RouteInfo):
                case nameof(RouteProgress):
                case nameof(RouteCoords):
                    Raise(nameof(NavActive)); Raise(nameof(NavDistanceText)); Raise(nameof(NavMilesLeftText));
                    Raise(nameof(NavSubtitle)); Raise(nameof(NavTurnGlyph)); Raise(nameof(RouteProgressPercentText));
                    Raise(nameof(RouteMilesLeftText)); Raise(nameof(RouteProgressVisible)); Raise(nameof(HasRouteValue));
                    Raise(nameof(RoutePercent));
                    break;
            }
        }

        // ---- Header / status ----------------------------------------------------------------------
        public string ConnectionStatus => Status;

        public Brush StatusBrush
        {
            get
            {
                switch (StatusColorValue)
                {
                    case StatusColor.Green: return ThemeBrushes.Green;
                    case StatusColor.Amber: return ThemeBrushes.Amber;
                    case StatusColor.Red:   return ThemeBrushes.Red;
                    default:                return ThemeBrushes.Dim;
                }
            }
        }

        // ---- DRIVE --------------------------------------------------------------------------------
        private const double MphPerKmh = 1.0 / 1.60934;

        /// <summary>
        /// Speed in MPH for the slider. The display reads mph because that is what the ELD app on
        /// the phone shows, and a tester's job is comparing the two screens. The WIRE is unchanged:
        /// field 3 is still km/h, converted in MTPacket. Mirrors the Swift build.
        /// </summary>
        public double SpeedSliderMph
        {
            get => SpeedMph;
            set
            {
                // Mac applies a route-speed floor: while driving a route the slider cannot go below 5 mph.
                double mph = DrivingRoute ? Math.Max(5, value) : value;
                if (Math.Abs(mph - SpeedMph) < 0.05) return;   // ignore the binding echo after we update SpeedMph
                SetSpeed(mph);
            }
        }

        public string SpeedMphText =>
            ((int)Math.Round(SpeedMph, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);

        // ---- Odometer sources (Sandeep, 13 Nov 2026) ------------------------------------------
        // One set of bindings per slot. WPF cannot index into a list from XAML cleanly, so each slot
        // gets explicit properties; the logic itself lives in Core's OdoLadder, shared with Swift.

        private OdoSourceConfig Src(int i) =>
            i < Config.OdoSources.Count ? Config.OdoSources[i] : new OdoSourceConfig(false, 0);

        public void RefreshOdoBindings() => OdoChanged();

        private void OdoChanged()
        {
            for (int i = 0; i < 4; i++)
            {
                Raise("OdoSrc" + i + "Enabled"); Raise("OdoSrc" + i + "Offset");
                Raise("OdoSrc" + i + "Text");    Raise("OdoSrc" + i + "Brush");
                Raise("OdoSrc" + i + "Locked");
            }
            Raise(nameof(OdoFlipEnabled));   // RESET TO CLEAN DATA clears it; the toggle must follow
            Raise(nameof(OdoSourceSummary)); Raise(nameof(OdoSourceSummaryBrush));
            Raise(nameof(OdoLockHint)); Raise(nameof(OdoLockHintBrush));
            Raise(nameof(OdoPrefixHint)); Raise(nameof(OdoFlipIntervalText));
        }

        private bool GetEnabled(int i) => Src(i).Enabled;
        private void SetEnabled(int i, bool v)
        {
            if (i >= Config.OdoSources.Count || Config.OdoSources[i].Enabled == v) return;
            Config.OdoSources[i].Enabled = v;
            // A source that is switched off cannot stay locked.
            if (!v && Config.OdoLockedSlot == i) Config.OdoLockedSlot = null;
            OdoChanged();
        }
        private double GetOffset(int i) => Src(i).OffsetMiles;
        private void SetOffset(int i, double v)
        {
            if (i >= Config.OdoSources.Count) return;
            v = Math.Round(v);
            if (Math.Abs(Config.OdoSources[i].OffsetMiles - v) < 0.001) return;
            Config.OdoSources[i].OffsetMiles = v;
            OdoChanged();
        }
        private bool GetLocked(int i) => Config.OdoLockedSlot == i;
        private void SetLocked(int i, bool v)
        {
            // Refuse to lock a source that is switched off. OdoLadder.Selected ignores a lock on an
            // inactive slot, so allowing it would show "locked" in the UI while the wire kept
            // flipping — the exact disagreement this panel exists to avoid.
            if (v && !Src(i).Enabled) { OdoChanged(); return; }
            Config.OdoLockedSlot = v ? i : (Config.OdoLockedSlot == i ? (int?)null : Config.OdoLockedSlot);
            OdoChanged();
        }
        private string SrcText(int i) =>
            Src(i).Enabled ? ((int)engine.OdoSourceMiles(i)).ToString(CultureInfo.InvariantCulture) + " mi" : "—";
        private Brush SrcBrush(int i) =>
            CurrentOdoSlot == i ? ThemeBrushes.Green : ThemeBrushes.Dim;

        public bool OdoSrc0Enabled { get => GetEnabled(0); set => SetEnabled(0, value); }
        public bool OdoSrc1Enabled { get => GetEnabled(1); set => SetEnabled(1, value); }
        public bool OdoSrc2Enabled { get => GetEnabled(2); set => SetEnabled(2, value); }
        public bool OdoSrc3Enabled { get => GetEnabled(3); set => SetEnabled(3, value); }
        public double OdoSrc0Offset { get => GetOffset(0); set => SetOffset(0, value); }
        public double OdoSrc1Offset { get => GetOffset(1); set => SetOffset(1, value); }
        public double OdoSrc2Offset { get => GetOffset(2); set => SetOffset(2, value); }
        public double OdoSrc3Offset { get => GetOffset(3); set => SetOffset(3, value); }
        public bool OdoSrc0Locked { get => GetLocked(0); set => SetLocked(0, value); }
        public bool OdoSrc1Locked { get => GetLocked(1); set => SetLocked(1, value); }
        public bool OdoSrc2Locked { get => GetLocked(2); set => SetLocked(2, value); }
        public bool OdoSrc3Locked { get => GetLocked(3); set => SetLocked(3, value); }
        public string OdoSrc0Text => SrcText(0);
        public string OdoSrc1Text => SrcText(1);
        public string OdoSrc2Text => SrcText(2);
        public string OdoSrc3Text => SrcText(3);
        public Brush OdoSrc0Brush => SrcBrush(0);
        public Brush OdoSrc1Brush => SrcBrush(1);
        public Brush OdoSrc2Brush => SrcBrush(2);
        public Brush OdoSrc3Brush => SrcBrush(3);

        public bool OdoFlipEnabled
        {
            get => Config.OdoFlipEnabled;
            set { if (Config.OdoFlipEnabled == value) return; Config.OdoFlipEnabled = value; OdoChanged(); Raise(nameof(OdoFlipEnabled)); }
        }
        public double OdoFlipIntervalSec
        {
            get => Config.OdoFlipIntervalSec;
            set { double v = Math.Round(value); if (Math.Abs(Config.OdoFlipIntervalSec - v) < 0.001) return;
                  Config.OdoFlipIntervalSec = v; Raise(nameof(OdoFlipIntervalSec)); Raise(nameof(OdoFlipIntervalText)); }
        }
        public string OdoFlipIntervalText => ((int)Config.OdoFlipIntervalSec).ToString(CultureInfo.InvariantCulture) + "s";

        public string OdoSourceSummary =>
            ActiveOdoSlots.Count >= 2 ? ActiveOdoSlots.Count + " sources" : "needs 2+";
        public Brush OdoSourceSummaryBrush =>
            ActiveOdoSlots.Count >= 2 ? ThemeBrushes.Green : ThemeBrushes.Amber;

        public string OdoLockHint => Config.OdoLockedSlot.HasValue
            ? "LOCKED — the live odometer stays on the locked source even while the flip is on. That is the 00FD fix under test."
            : "Live odometer alternates between the two highest-priority sources, like the customer's 00F6 data.";
        public Brush OdoLockHintBrush => Config.OdoLockedSlot.HasValue ? ThemeBrushes.Amber : ThemeBrushes.Dim;

        public string OdoPrefixHint => Config.OdoReportPrefix == "LO"
            ? "00FD sends LO. The ELD app only reads XO, so it will DROP this one — use it to check the wire, not the phone."
            : "The app parses XO, but stores it in a variable nothing reads — so still nothing shows on the phone.";

        public string ModeText
        {
            get
            {
                // Mirror macOS ControlsDrawer.modeText exactly: ROUTE / AUTO CRUISE / MANUAL / PARKED.
                if (DrivingRoute) return "ROUTE";
                if (AutoDrive) return "AUTO CRUISE";
                return IgnitionOn ? "MANUAL" : "PARKED";
            }
        }

        // ---- SCENARIO -----------------------------------------------------------------------------

        // ---- Active button states (filled highlight, mirrors NeonButton filled:) ------------------
        public bool ActiveSpeedStop => SpeedMph < 0.5;
        public bool ActiveSpeed35 => Math.Abs(SpeedMph - 35) < 3;
        public bool ActiveSpeed55 => Math.Abs(SpeedMph - 55) < 3;
        public bool ActiveSpeed70 => Math.Abs(SpeedMph - 70) < 3;
        public bool ActiveT1 => (int)Math.Round(Config.RouteTimeScale) == 1;
        public bool ActiveT5 => (int)Math.Round(Config.RouteTimeScale) == 5;
        public bool ActiveT10 => (int)Math.Round(Config.RouteTimeScale) == 10;
        public bool ActiveT25 => (int)Math.Round(Config.RouteTimeScale) == 25;
        public bool ActiveT30 => (int)Math.Round(Config.RouteTimeScale) == 30;
        public bool ActiveSigFull => !LinkDown && (int)Math.Round(Config.SignalPct) == 100;
        public bool ActiveSigAuto => AutoSignal;
        public bool ActiveSigPoor => !LinkDown && (int)Math.Round(Config.SignalPct) == 25;

        // RSSI slider (0–100% → ESP32 real TX power). Two-way: dragging it turns AUTO off and drives the signal.
        public double SignalSlider
        {
            get => Config.SignalPct;
            set { AutoSignal = false; SetSignal(value); Raise(nameof(SignalSlider)); Raise(nameof(SignalDbmLabel)); }
        }
        public string SignalDbmLabel =>
            Config.Link == SimConfig.Transport.Esp32Serial ? $"{Config.TxPowerDbm:+0;-0;0} dBm" : "n/a (BLE)";
        public bool UseEsp32 => Config.Link == SimConfig.Transport.Esp32Serial;

        // ---- CONNECTION / SIGNAL (F1) -------------------------------------------------------------
        public string SignalState
        {
            get
            {
                if (LinkDown) return "OUT OF RANGE";
                double pct = Config.SignalPct;
                // Mac signalState has no NONE tier — 0% reads "POOR · 0%".
                string tier = pct >= 80 ? "FULL" : pct >= 40 ? "WEAK" : "POOR";
                return $"{tier} · {(int)Math.Round(pct)}%";
            }
        }

        public Brush SignalColor
        {
            get
            {
                if (LinkDown) return ThemeBrushes.Red;
                double pct = Config.SignalPct;
                return pct >= 80 ? ThemeBrushes.Green : pct >= 40 ? ThemeBrushes.Amber : ThemeBrushes.Red;
            }
        }

        public string OutageCountdown
        {
            get
            {
                // Match macOS outageCountdown strings verbatim.
                if (DropEndsAt == null) return "out of range";
                int r = (int)Math.Ceiling((DropEndsAt.Value - DateTime.UtcNow).TotalSeconds);
                return r > 0 ? $"back in range in {r}s" : "reconnecting…";
            }
        }

        public double RangeOutageSec
        {
            get => Config.RangeOutageSec;
            set { Config.RangeOutageSec = value; Raise(nameof(RangeOutageSec)); Raise(nameof(RangeOutageText)); }
        }
        public string RangeOutageText => $"{(int)Math.Round(Config.RangeOutageSec)}s";

        // ---- TEST SETUP: editable odometer / engine hours -----------------------------------------
        // Dial the truck to a starting state instead of driving to it. Both are FORWARD ONLY while the
        // app is connected (SetOdometer/SetEngineHours enforce it and log the refusal), so the getter
        // re-reads the live value rather than echoing whatever was typed.
        public string OdometerInput
        {
            get => OdometerMiles.ToString("F1", CultureInfo.InvariantCulture);
            set
            {
                if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double v)) SetOdometer(v);
                Raise(nameof(OdometerInput));
            }
        }

        public string EngineHoursInput
        {
            get => EngineHours.ToString("F2", CultureInfo.InvariantCulture);
            set
            {
                if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double v)) SetEngineHours(v);
                Raise(nameof(EngineHoursInput));
            }
        }

        // Must track the same flag the setter gates on (Connected), or the caption promises
        // "any value" during a watchdog lapse while the app is still attached.
        public string SetupHint => Connected
            ? "forward only while the app is connected"
            : "any value — no app connected";

        /// <summary>
        /// In ESP32 mode the slider really is RSSI — it drives the board's BLE TX power, so the phone
        /// reads a different dBm. In BLE mode there is no TX-power API, so it only shapes the emulated
        /// link (latency, and out-of-range at 0); calling it RSSI there would promise what the PC cannot do.
        /// </summary>
        public string SignalSliderLabel => Config.Link == SimConfig.Transport.Esp32Serial ? "RSSI" : "SIGNAL";

        // ---- STORED DUMP (F2) ---------------------------------------------------------------------
        public int StoredDumpCount
        {
            get => Config.StoredDumpCount;
            set { Config.StoredDumpCount = value; Raise(nameof(StoredDumpCount)); Raise(nameof(StoredDumpCountText)); }
        }
        public string StoredDumpCountText => $"{Config.StoredDumpCount} pkts";

        public double StoredDumpCadenceSec
        {
            get => Config.StoredDumpCadenceSec;
            set { Config.StoredDumpCadenceSec = value; Raise(nameof(StoredDumpCadenceSec)); Raise(nameof(StoredDumpCadenceText)); }
        }
        public string StoredDumpCadenceText => $"{Config.StoredDumpCadenceSec.ToString("0.00", CultureInfo.InvariantCulture)}s";

        // ---- RAW EFFECTS --------------------------------------------------------------------------
        public double PacketLossPct
        {
            get => Config.PacketLossPct;
            set { Config.PacketLossPct = value; Raise(nameof(PacketLossPct)); Raise(nameof(PacketLossText)); }
        }
        public string PacketLossText => $"{(int)Math.Round(Config.PacketLossPct)}%";

        public double DuplicatePct
        {
            get => Config.DuplicatePct;
            set { Config.DuplicatePct = value; Raise(nameof(DuplicatePct)); Raise(nameof(DuplicateText)); }
        }
        public string DuplicateText => $"{(int)Math.Round(Config.DuplicatePct)}%";

        public double OutOfOrderPct
        {
            get => Config.OutOfOrderPct;
            set { Config.OutOfOrderPct = value; Raise(nameof(OutOfOrderPct)); Raise(nameof(OutOfOrderText)); }
        }
        public string OutOfOrderText => $"{(int)Math.Round(Config.OutOfOrderPct)}%";

        public double PacketIntervalSec
        {
            get => Config.PacketIntervalSec;
            set { Config.PacketIntervalSec = value; Raise(nameof(PacketIntervalSec)); Raise(nameof(PacketIntervalText)); }
        }
        public string PacketIntervalText => $"{Config.PacketIntervalSec.ToString("0.00", CultureInfo.InvariantCulture)}s";

        // ---- DIAGNOSTICS --------------------------------------------------------------------------
        public string FaultsText => (Faults == null || Faults.Count == 0) ? "none" : string.Join("  ", Faults);

        // ---- LOG ----------------------------------------------------------------------------------
        public string LogCountText => $"{Log.Count} lines";
        public void ClearLog() => PostToUi(() => { Log.Clear(); Raise(nameof(LogCountText)); });

        // ---- Brushes (frozen theme colours) -------------------------------------------------------
        private string _clockText = DateTime.Now.ToString("HH:mm", CultureInfo.InvariantCulture);
        public string ClockText => _clockText;
        public string TempText => $"· {AmbientTempC}°";

        // ---- Gauges -------------------------------------------------------------------------------
        public double SpeedFraction => Math.Max(0, Math.Min(1, SpeedMph / 120.0));   // dial reads 0-120 mph
        public string SpeedCenterText => ((int)Math.Round(SpeedMph, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
        public double TachFraction => Math.Max(0, Math.Min(1, Rpm / 3000.0));
        public bool TachHot => Rpm / 3000.0 > 0.82;
        public string RpmText => Rpm.ToString(CultureInfo.InvariantCulture);

        public string GearValue => Gear;

        public Brush ModeBrush
        {
            get
            {
                // Mirror macOS modeTint: green when driving a route, red under auto cruise, ice when on, dim when parked.
                if (DrivingRoute) return ThemeBrushes.Green;
                if (AutoDrive) return ThemeBrushes.Red;
                return IgnitionOn ? ThemeBrushes.Ice : ThemeBrushes.Dim;
            }
        }

        // ---- Header / VIN -------------------------------------------------------------------------
        public string VinDisplay => string.IsNullOrEmpty(Vin) ? "SET VIN" : Vin;
        public string VinBadge => (Vin != null && Vin.Length == 17) ? "VALID" : "TEST";
        public Brush VinBadgeBrush => (Vin != null && Vin.Length == 17) ? ThemeBrushes.Green : ThemeBrushes.Amber;

        // ---- Telemetry dock -----------------------------------------------------------------------
        public string OdometerText => OdometerMiles.ToString("F0", CultureInfo.InvariantCulture);
        public string TripText => TripMiles.ToString("F1", CultureInfo.InvariantCulture);
        public string EngineHoursText => EngineHours.ToString("F1", CultureInfo.InvariantCulture);
        public string HeadingText => HeadingDeg.ToString(CultureInfo.InvariantCulture);
        public string SatellitesText => Satellites.ToString(CultureInfo.InvariantCulture);
        public Brush SatsBrush => Satellites >= 4 ? ThemeBrushes.Green : ThemeBrushes.Amber;
        public string EcmText => EcmActive ? "ON" : "OFF";
        public Brush EcmBrush => EcmActive ? ThemeBrushes.Green : ThemeBrushes.Dim;

        // ---- Fuel ---------------------------------------------------------------------------------
        public Color FuelTintColor => FuelPct < 20 ? ((SolidColorBrush)ThemeBrushes.Red).Color : ((SolidColorBrush)ThemeBrushes.Green).Color;
        public Color Fuel2TintColor => Fuel2Pct < 20 ? ((SolidColorBrush)ThemeBrushes.Red).Color : ((SolidColorBrush)ThemeBrushes.Blue).Color;
        public Brush FuelBrush => FuelPct < 20 ? ThemeBrushes.Red : ThemeBrushes.Green;
        public Brush Fuel2Brush => Fuel2Pct < 20 ? ThemeBrushes.Red : ThemeBrushes.Blue;
        public string FuelPctText => $"{(int)FuelPct}%";        // Mac uses Int() truncation, not rounding
        public string Fuel2PctText => $"{(int)Fuel2Pct}%";
        public double FuelSlider { get => FuelPct; set => SetFuel(value); }
        public double Fuel2Slider { get => Fuel2Pct; set => SetFuel2(value); }

        // ---- Nav strip ----------------------------------------------------------------------------
        public bool NavActive => HasRoute;
        public bool HasRouteValue => HasRoute;
        public string NavDistanceText
        {
            get
            {
                if (!HasRoute) return "No active route";
                double m = RouteRemainingMeters;
                return m >= 1000 ? $"{(m / 1000).ToString("F1", CultureInfo.InvariantCulture)} km" : $"{(int)m} m";
            }
        }
        public string NavSubtitle => HasRoute ? "Continue on route" : "Plan or randomize a route in the Flight Deck";
        public string NavMilesLeftText => $"{RouteMilesLeft} mi left";
        public string NavTurnGlyph
        {
            get
            {
                if (!Route.HasRoute) return "⊘";
                var (icon, _) = NextTurn;
                switch (icon)
                {
                    case "arrow.turn.up.right": return "↱";
                    case "arrow.turn.up.left": return "↰";
                    case "arrow.uturn.up": return "⤺";
                    case "arrow.up": return "↑";
                    default: return "⊘";
                }
            }
        }

        // ---- Route panel --------------------------------------------------------------------------
        public double RoutePercent => RouteProgress * 100.0;
        public string RouteProgressPercentText => $"{(int)(RouteProgress * 100)}% complete";
        public string RouteMilesLeftText => $"{RouteMilesLeft} mi left";
        public bool RouteProgressVisible => DrivingRoute || RouteProgress > 0;

        // ---- Connection ---------------------------------------------------------------------------
        public Brush SignalBrush
        {
            get
            {
                if (LinkDown || Config.SignalPct < 20) return ThemeBrushes.Red;
                if (Config.SignalPct < 50) return ThemeBrushes.Amber;
                return ThemeBrushes.Green;
            }
        }
        public bool LinkDownVisible => LinkDown;
        public bool IsDumping => RunningDump != null && RunningDump.StartsWith("Stored dump", StringComparison.Ordinal);

        // ---- Diagnostics --------------------------------------------------------------------------
        public bool FaultsEmpty => Faults == null || Faults.Count == 0;
        private bool HasFault(string code) => Faults != null && Faults.Contains(code);
        public bool FaultP0143 => HasFault("P0143");
        public bool FaultP0217 => HasFault("P0217");
        public bool FaultC0035 => HasFault("C0035");
        public bool FaultU0101 => HasFault("U0101");
        public Brush DtcButtonBrush => FaultsEmpty ? ThemeBrushes.Dim : ThemeBrushes.Amber;
        // Mac footer shows "DTC" / "DTC (n)" with a live fault count.
        public string DtcButtonText => FaultsEmpty ? "🔧 DIAGNOSTICS · DTC" : $"🔧 DIAGNOSTICS · DTC ({Faults.Count})";

        // ---- Footer -------------------------------------------------------------------------------
        public string FooterStatusText => $"Advertising as ELD-MA · {(Streaming ? "streaming" : "waiting for ELD app")}";

        // ---- Ignition overlay ---------------------------------------------------------------------
        public bool IgnitionVisible => Phase != ClusterPhase.Live;
        public bool IsCold => Phase == ClusterPhase.Cold;
        public bool SweepVisible => Phase != ClusterPhase.Live && Phase != ClusterPhase.Cold;
        public double SweepFraction => Phase == ClusterPhase.Sweep ? 1.0 : (Phase == ClusterPhase.Settle ? 0.12 : 0.0);
        public string SweepSpeedText => ((int)(SweepFraction * 150)).ToString(CultureInfo.InvariantCulture);
        public string SweepRpmText => ((int)(SweepFraction * 3000)).ToString(CultureInfo.InvariantCulture);
        public bool SystemsNominalVisible => Phase == ClusterPhase.Settle;
    }
}
