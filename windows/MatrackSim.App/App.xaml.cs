using System;
using System.Windows;
using System.Windows.Threading;

namespace MatrackSim.App
{
    /// <summary>WPF application entry point. Theme + resources live in App.xaml.</summary>
    public partial class App : Application
    {
        public App()
        {
            // Keep the cockpit alive if a non-fatal UI exception slips through (e.g. a transient
            // binding/layout hiccup); log it to the console instead of tearing down the window.
            DispatcherUnhandledException += OnDispatcherUnhandledException;
        }

        private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            Console.WriteLine($"[ui-exception] {e.Exception.GetType().Name}: {e.Exception.Message}");
            e.Handled = true;
        }
    }
}
