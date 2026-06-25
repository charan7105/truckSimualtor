using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;

namespace MatrackSim.App.Controls
{
    /// <summary>
    /// Panel container matching ControlsDrawer.swift's Card: glass body, a tinted gradient accent bar
    /// across the top, and an icon + section-label header. Inner content goes in the default child slot.
    /// </summary>
    [ContentProperty(nameof(InnerContent))]
    public sealed class Card : Control
    {
        static Card()
        {
            DefaultStyleKeyProperty.OverrideMetadata(typeof(Card), new FrameworkPropertyMetadata(typeof(Card)));
        }

        public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(
            nameof(Title), typeof(string), typeof(Card), new PropertyMetadata(""));
        public string Title { get => (string)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }

        public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(
            nameof(Glyph), typeof(string), typeof(Card), new PropertyMetadata(""));
        public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }

        public static readonly DependencyProperty TintProperty = DependencyProperty.Register(
            nameof(Tint), typeof(Brush), typeof(Card), new PropertyMetadata(Brushes.Gray));
        public Brush Tint { get => (Brush)GetValue(TintProperty); set => SetValue(TintProperty, value); }

        public static readonly DependencyProperty InnerContentProperty = DependencyProperty.Register(
            nameof(InnerContent), typeof(object), typeof(Card), new PropertyMetadata(null));
        public object InnerContent { get => GetValue(InnerContentProperty); set => SetValue(InnerContentProperty, value); }
    }
}
