import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads track points from GPX files (exports from Garmin Connect, Strava, Komoot, ...).
/// Each `<trkseg>` / `<rte>` becomes its own track so gaps between segments are not bridged.
public final class GPXParser: NSObject, XMLParserDelegate {
    private var tracks: [[GeoPoint]] = []
    private var current: [GeoPoint] = []

    public static func tracks(from data: Data) -> [[GeoPoint]] {
        let delegate = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        delegate.flush()
        return delegate.tracks
    }

    private func flush() {
        if !current.isEmpty { tracks.append(current) }
        current = []
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                       qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "trkseg", "rte":
            flush()
        case "trkpt", "rtept", "wpt":
            if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
               (-90...90).contains(lat), (-180...180).contains(lon) {
                current.append(GeoPoint(latitude: lat, longitude: lon))
            }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["trkseg", "rte"].contains(localName(elementName)) { flush() }
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
