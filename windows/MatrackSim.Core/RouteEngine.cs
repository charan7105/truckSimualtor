using System;
using System.Collections.Generic;

namespace MatrackSim.Core
{
    // MARK: - Coordinate
    //
    // Swift used CoreLocation's CLLocationCoordinate2D (a simple lat/lon pair).
    // CoreLocation is Apple-only, so we mirror it here with a plain struct that
    // carries the same two fields and value semantics.
    public struct Coordinate
    {
        public double Latitude;
        public double Longitude;

        public Coordinate(double latitude, double longitude)
        {
            Latitude = latitude;
            Longitude = longitude;
        }
    }

    // MARK: - Geo math

    public static class Geo
    {
        public const double EarthRadiusM = 6_371_000.0;

        /// Great-circle distance in meters between two coordinates.
        public static double Meters(Coordinate a, Coordinate b)
        {
            double lat1 = a.Latitude * Math.PI / 180, lat2 = b.Latitude * Math.PI / 180;
            double dLat = (b.Latitude - a.Latitude) * Math.PI / 180;
            double dLon = (b.Longitude - a.Longitude) * Math.PI / 180;
            double h = Math.Sin(dLat / 2) * Math.Sin(dLat / 2)
                + Math.Cos(lat1) * Math.Cos(lat2) * Math.Sin(dLon / 2) * Math.Sin(dLon / 2);
            return EarthRadiusM * 2 * Math.Atan2(Math.Sqrt(h), Math.Sqrt(1 - h));
        }

        /// Initial bearing (degrees 0-359) from a -> b.
        public static int Bearing(Coordinate a, Coordinate b)
        {
            double lat1 = a.Latitude * Math.PI / 180, lat2 = b.Latitude * Math.PI / 180;
            double dLon = (b.Longitude - a.Longitude) * Math.PI / 180;
            double y = Math.Sin(dLon) * Math.Cos(lat2);
            double x = Math.Cos(lat1) * Math.Sin(lat2) - Math.Sin(lat1) * Math.Cos(lat2) * Math.Cos(dLon);
            double deg = Math.Atan2(y, x) * 180 / Math.PI;
            // Swift: Int((deg + 360).truncatingRemainder(dividingBy: 360))
            // truncatingRemainder == C# IEEERemainder? No: Swift truncatingRemainder
            // matches the C# % operator (truncated, sign of dividend), so use %.
            // Int(...) truncates toward zero, matching (int) cast.
            return (int)((deg + 360) % 360);
        }

        /// Linearly interpolate between a and b at fraction t (0-1).
        public static Coordinate Interp(Coordinate a, Coordinate b, double t)
        {
            return new Coordinate(
                a.Latitude + (b.Latitude - a.Latitude) * t,
                a.Longitude + (b.Longitude - a.Longitude) * t);
        }
    }

    // MARK: - Route engine: drives a polyline, producing position/heading/distance

    /// Result of a position lookup: a coordinate plus an integer heading in degrees.
    /// Mirrors the Swift tuple (coord: CLLocationCoordinate2D, headingDeg: Int).
    public struct RoutePosition
    {
        public Coordinate Coord;
        public int HeadingDeg;

        public RoutePosition(Coordinate coord, int headingDeg)
        {
            Coord = coord;
            HeadingDeg = headingDeg;
        }
    }

    /// Holds a route as a list of coordinates and advances a "vehicle" along it by distance.
    public sealed class RouteEngine
    {
        public List<Coordinate> Coords { get; private set; } = new List<Coordinate>();
        private List<double> _cumMeters = new List<double>();   // cumulative distance to each coord
        public double TraveledMeters { get; private set; } = 0;

        public double TotalMeters => _cumMeters.Count > 0 ? _cumMeters[_cumMeters.Count - 1] : 0;
        public double TotalMiles => TotalMeters * 0.000621371;
        public bool HasRoute => Coords.Count >= 2;
        public bool IsComplete => HasRoute && TraveledMeters >= TotalMeters;
        public double ProgressFraction => TotalMeters > 0 ? Math.Min(1, TraveledMeters / TotalMeters) : 0;

        public void SetRoute(List<Coordinate> c)
        {
            Coords = c;
            _cumMeters = new List<double>();
            double sum = 0.0;
            for (int i = 0; i < c.Count; i++)
            {
                if (i == 0) { _cumMeters.Add(0); }
                else { sum += Geo.Meters(c[i - 1], c[i]); _cumMeters.Add(sum); }
            }
            TraveledMeters = 0;
        }

        public void Reset() { TraveledMeters = 0; }

        /// Advance by `meters` along the route. Returns the new position + heading, or null if no route.
        public RoutePosition? Advance(double meters)
        {
            if (!HasRoute) { return null; }
            TraveledMeters = Math.Min(TotalMeters, TraveledMeters + Math.Max(0, meters));
            return PositionAt(TraveledMeters);
        }

        /// Position + heading at a given distance along the route.
        public RoutePosition PositionAt(double dist)
        {
            if (!HasRoute)
            {
                Coordinate first = Coords.Count > 0 ? Coords[0] : new Coordinate(0, 0);
                return new RoutePosition(first, 0);
            }
            if (dist <= 0) { return new RoutePosition(Coords[0], Geo.Bearing(Coords[0], Coords[1])); }
            if (dist >= TotalMeters)
            {
                int n = Coords.Count;
                return new RoutePosition(Coords[n - 1], Geo.Bearing(Coords[n - 2], Coords[n - 1]));
            }
            // find the segment containing `dist`
            int seg = 1;
            while (seg < _cumMeters.Count && _cumMeters[seg] < dist) { seg += 1; }
            Coordinate a = Coords[seg - 1], b = Coords[seg];
            double segStart = _cumMeters[seg - 1], segLen = _cumMeters[seg] - segStart;
            double t = segLen > 0 ? (dist - segStart) / segLen : 0;
            return new RoutePosition(Geo.Interp(a, b, t), Geo.Bearing(a, b));
        }
    }

    // MARK: - Directions: resolve "from -> to" into a drivable route
    //
    // The Swift original used MapKit (MKLocalSearch / MKDirections) to geocode
    // place strings and compute a driving polyline. MapKit is Apple-only and has
    // no netstandard2.0 equivalent, so the routing implementation is intentionally
    // NOT ported here. On Windows the route will be supplied by a different
    // mechanism (e.g. an external routing service feeding SetRoute directly).
    //
    // This stub preserves the public shape so callers can be wired up, but every
    // method throws NotImplementedOnThisPlatform.

    /// Thrown by the Directions stub: route resolution is platform-specific and
    /// is not available in the cross-platform Core library.
    public sealed class NotImplementedOnThisPlatform : Exception
    {
        public NotImplementedOnThisPlatform()
            : base("Directions routing is not available on this platform; supply a route via RouteEngine.SetRoute.") { }
    }

    public static class Directions
    {
        /// Geocode a free-text place to a coordinate. (MapKit-only; not ported.)
        public static Coordinate Geocode(string query)
        {
            throw new NotImplementedOnThisPlatform();
        }

        /// Compute a driving route between two place strings. (MapKit-only; not ported.)
        public static List<Coordinate> Route(string from, string to)
        {
            throw new NotImplementedOnThisPlatform();
        }

        /// Compute a driving route between two coordinates. (MapKit-only; not ported.)
        public static List<Coordinate> Route(Coordinate origin, Coordinate dest)
        {
            throw new NotImplementedOnThisPlatform();
        }
    }
}
