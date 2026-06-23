using System;
using System.Collections.Specialized;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using MatrackSim.Core;

namespace MatrackSim.App
{
    /// <summary>
    /// Operator-panel UI for the Windows tracker simulator. Mirrors the control set of the
    /// Swift cluster (ControlsDrawer.swift): DRIVE, ROUTE (DRIVE MY DAY), SCENARIO,
    /// CONNECTION/SIGNAL (F1 outage + F2 stored dump + raw effects), DIAGNOSTICS, and the
    /// live packet stream.
    ///
    /// The view-model is the assumed <see cref="TrackerPeripheral"/> (INotifyPropertyChanged),
    /// the C# counterpart of the Swift SimController. All button handlers forward verbatim to
    /// its methods so behaviour matches the Swift exactly.
    ///
    /// TODO (not ported yet): the twin Ø360 instrument-cluster gauges and the route map view.
    /// </summary>
    public partial class MainWindow : Window
    {
        private TrackerPeripheral Sim => (TrackerPeripheral)DataContext;

        public MainWindow()
        {
            InitializeComponent();
            DataContext = new TrackerPeripheral();

            // Auto-scroll the packet stream to the newest line (mirrors ScrollViewReader.scrollTo).
            Sim.Log.CollectionChanged += Log_CollectionChanged;
        }

        private void Log_CollectionChanged(object sender, NotifyCollectionChangedEventArgs e)
        {
            if (e.Action == NotifyCollectionChangedAction.Add && LogList.Items.Count > 0)
            {
                LogList.ScrollIntoView(LogList.Items[LogList.Items.Count - 1]);
            }
        }

        // MARK: - DRIVE
        private void SpeedPreset_Click(object sender, RoutedEventArgs e)
        {
            int kmh = int.Parse((string)((Button)sender).Tag, CultureInfo.InvariantCulture);
            Sim.SetSpeed(kmh / 1.60934);   // Swift: sim.setSpeed(Double(v) / 1.60934)
        }

        private void TimeScale_Click(object sender, RoutedEventArgs e)
        {
            int x = int.Parse((string)((Button)sender).Tag, CultureInfo.InvariantCulture);
            Sim.Config.RouteTimeScale = x;   // Swift: sim.config.routeTimeScale = Double(x)
        }

        // MARK: - ROUTE
        private async void DriveMyDay_Click(object sender, RoutedEventArgs e)
        {
            if (Sim.DayDriving) Sim.StopDay();
            else await Sim.DriveMyDay();
        }

        // MARK: - SCENARIO
        private void RunScenario_Click(object sender, RoutedEventArgs e)
        {
            if (Sim.SelectedScenario != null) Sim.RunScenario(Sim.SelectedScenario);
        }

        private void StopScenario_Click(object sender, RoutedEventArgs e) => Sim.StopScenario();

        // MARK: - CONNECTION / SIGNAL (F1)
        private void Signal_Click(object sender, RoutedEventArgs e)
        {
            double pct = double.Parse((string)((Button)sender).Tag, CultureInfo.InvariantCulture);
            Sim.SetSignal(pct);
        }

        private void Drop_Click(object sender, RoutedEventArgs e)
        {
            if (Sim.LinkDown) Sim.ResumeLink();
            else Sim.ForceDisconnect(Sim.Config.RangeOutageSec);
        }

        // MARK: - STORED DUMP (F2)
        private void Dump_Click(object sender, RoutedEventArgs e)
        {
            Sim.DumpStoredPackets(Sim.Config.StoredDumpCount, Sim.Config.StoredDumpCadenceSec);
        }

        // MARK: - DIAGNOSTICS
        private void Fault_Click(object sender, RoutedEventArgs e) =>
            Sim.InjectFault((string)((Button)sender).Tag);

        private void ClearFaults_Click(object sender, RoutedEventArgs e) => Sim.ClearFaults();

        // MARK: - LOG
        private void ClearLog_Click(object sender, RoutedEventArgs e) => Sim.ClearLog();
    }
}
