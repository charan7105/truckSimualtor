using System;
using System.Collections.Specialized;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;
using MatrackSim.Core;

namespace MatrackSim.App
{
    /// <summary>
    /// Full cluster cockpit for the Windows tracker simulator — a faithful WPF reproduction of the
    /// macOS SwiftUI dashboard (ContentView + the cluster widgets). All button handlers forward verbatim
    /// to the verified <see cref="TrackerPeripheral"/> controller so behaviour matches the Mac exactly.
    /// </summary>
    public partial class MainWindow : Window
    {
        private TrackerPeripheral Sim => (TrackerPeripheral)DataContext;

        public MainWindow()
        {
            InitializeComponent();
            DataContext = new TrackerPeripheral();
            Sim.Log.CollectionChanged += Log_CollectionChanged;

            // Dark, Mac-like title bar instead of the default white Windows chrome.
            SourceInitialized += (s, e) => EnableDarkTitleBar();
            // A maximized WPF window overhangs the monitor by ~7px on every edge, clipping content flush to
            // the border (the footer DTC/REPLAY buttons). Inset the cockpit by that much only when maximized.
            StateChanged += (s, e) => ApplyMaximizeInset();
            Loaded += (s, e) => ApplyMaximizeInset();

            // `demo` arg: skip the ignition sweep, load a random route and drive it — mirrors ContentView.onAppear.
            if (Environment.GetCommandLineArgs().Length > 1 && Environment.GetCommandLineArgs()[1] == "demo")
            {
                Loaded += async (s, e) =>
                {
                    Sim.SkipStartup();
                    await System.Threading.Tasks.Task.Delay(800);
                    await Sim.LoadRandomRoute();
                    Sim.StartRouteDrive();
                };
            }
        }

        // MARK: - Window chrome (dark title bar + maximized-overhang fix)

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        private void EnableDarkTitleBar()
        {
            try
            {
                IntPtr hwnd = new WindowInteropHelper(this).Handle;
                if (hwnd == IntPtr.Zero) return;
                int useDark = 1;
                // DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (Win10 2004+/Win11); 19 was the pre-release value.
                if (DwmSetWindowAttribute(hwnd, 20, ref useDark, sizeof(int)) != 0)
                    DwmSetWindowAttribute(hwnd, 19, ref useDark, sizeof(int));
            }
            catch { /* DWM unavailable — fall back to default chrome */ }
        }

        private void ApplyMaximizeInset()
        {
            RootGrid.Margin = WindowState == WindowState.Maximized
                ? new Thickness(SystemParameters.WindowResizeBorderThickness.Left + 1)
                : new Thickness(0);
        }

        private void Log_CollectionChanged(object sender, NotifyCollectionChangedEventArgs e)
        {
            if (e.Action != NotifyCollectionChangedAction.Add) return;
            // Defer the auto-scroll: calling ScrollIntoView synchronously inside CollectionChanged forces a
            // layout pass before the ListBox finishes recording this Add, which trips WPF's generator
            // consistency check ("ItemsControl is inconsistent with its items source"). Background priority
            // runs it after the Add is fully processed.
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (LogList.Items.Count > 0)
                    LogList.ScrollIntoView(LogList.Items[LogList.Items.Count - 1]);
            }), DispatcherPriority.Background);
        }

        // MARK: - DRIVE
        private void Engine_Click(object sender, RoutedEventArgs e) => Sim.SetEngine(!Sim.IgnitionOn);
        private void Auto_Click(object sender, RoutedEventArgs e) => Sim.SetAutoDrive(!Sim.AutoDrive);

        private static string Param(object sender) =>
            (string)((System.Windows.Controls.Primitives.ButtonBase)sender).CommandParameter;

        private void SpeedPreset_Click(object sender, RoutedEventArgs e)
        {
            int kmh = int.Parse(Param(sender), CultureInfo.InvariantCulture);
            Sim.SetSpeed(kmh / 1.60934);   // Swift: sim.setSpeed(Double(v) / 1.60934)
        }

        private void TimeScale_Click(object sender, RoutedEventArgs e)
        {
            int x = int.Parse(Param(sender), CultureInfo.InvariantCulture);
            Sim.Config.RouteTimeScale = x;
        }

        // MARK: - ROUTE
        private async void Plan_Click(object sender, RoutedEventArgs e) => await Sim.LoadRoute(Sim.RouteFrom, Sim.RouteTo);
        private async void Random_Click(object sender, RoutedEventArgs e) => await Sim.LoadRandomRoute();

        private void DriveRoute_Click(object sender, RoutedEventArgs e)
        {
            if (Sim.DrivingRoute) Sim.StopRouteDrive();
            else Sim.StartRouteDrive();
        }

        private async void DriveMyDay_Click(object sender, RoutedEventArgs e)
        {
            if (Sim.DayDriving) Sim.StopDay();
            else await Sim.DriveMyDay();
        }

        // MARK: - SCENARIO
        private void ScenarioToggle_Click(object sender, RoutedEventArgs e)
        {
            if (Sim.RunningScenario != null) Sim.StopScenario();
            else if (Sim.SelectedScenario != null) Sim.RunScenario(Sim.SelectedScenario);
        }
        private void Steps_Click(object sender, RoutedEventArgs e) => StepsPopup.IsOpen = !StepsPopup.IsOpen;

        // MARK: - CONNECTION / SIGNAL
        private void Signal_Click(object sender, RoutedEventArgs e)
        {
            double pct = double.Parse(Param(sender), CultureInfo.InvariantCulture);
            Sim.SetSignal(pct);
        }

        private void Drop_Click(object sender, RoutedEventArgs e)
        {
            // Windows reconnect fix: use the soft "out of range" model (keep the GattServiceProvider alive and
            // advertising; just go silent) instead of a hard teardown. On Windows, tearing the provider down and
            // re-creating it on resume changes the BLE advertising identity, so the iPhone — which auto-reconnects
            // to the peripheral identity it cached at first connect — never recognizes the re-advertised peripheral
            // (CoreBluetooth keeps that identity stable across teardown, which is why the Mac reconnects). Keeping
            // the same provider advertising preserves the identity, so the app times out, drops, and reconnects to
            // the still-live peripheral — the same conditions as the initial connect, which works. See DropLink.
            if (Sim.LinkDown) Sim.ResumeLink();
            else Sim.DropLink(Sim.Config.RangeOutageSec);
        }

        private void Dump_Click(object sender, RoutedEventArgs e) =>
            Sim.DumpStoredPackets(Sim.Config.StoredDumpCount, Sim.Config.StoredDumpCadenceSec);

        // MARK: - DIAGNOSTICS
        private void Dtc_Click(object sender, RoutedEventArgs e) => DtcPopup.IsOpen = !DtcPopup.IsOpen;
        private void Fault_Click(object sender, RoutedEventArgs e) => Sim.InjectFault(Param(sender));
        private void ClearFaults_Click(object sender, RoutedEventArgs e) => Sim.ClearFaults();

        // MARK: - IGNITION
        private void Start_Click(object sender, RoutedEventArgs e) => Sim.BeginStartup();
        private void Ignition_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (!Sim.IsCold) Sim.SkipStartup();   // tap anywhere (except in the cold state) skips the sweep
        }
        private void ReplayIgnition_Click(object sender, RoutedEventArgs e) => Sim.RearmStartup();

        // MARK: - LOG
        private void ClearLog_Click(object sender, RoutedEventArgs e) => Sim.ClearLog();

        private void ExportLog_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new SaveFileDialog
            {
                Title = "Export Packet Log",
                FileName = "matrack-packets.txt",
                Filter = "Text file (*.txt)|*.txt",
            };
            if (dlg.ShowDialog(this) != true) return;
            var sb = new StringBuilder();
            sb.AppendLine("Matrack Truck Sim — packet log");
            sb.AppendLine($"VIN: {Sim.Vin}");
            sb.AppendLine($"Exported: {DateTime.Now}");
            sb.AppendLine($"Lines: {Sim.Log.Count}");
            sb.AppendLine();
            foreach (var l in Sim.Log) sb.AppendLine($"{l.Time}  {l.Symbol}  {l.Text}");
            try { File.WriteAllText(dlg.FileName, sb.ToString()); } catch { /* user cancelled / locked */ }
        }
    }
}
