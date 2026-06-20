import Foundation

enum SonosXML {
    static func firstValue(for tag: String, in xml: String) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<(?:\\w+:)?\(escapedTag)(?:\\s[^>]*)?>(.*?)</(?:\\w+:)?\(escapedTag)>"

        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
            let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
            let range = Range(match.range(at: 1), in: xml)
        else {
            return nil
        }

        return decodeEntities(String(xml[range])).nilIfBlank
    }

    /// Extracts the value of an attribute (e.g. `val`) on the first matching tag.
    /// UPnP `LastChange` events encode state as attributes: `<TransportState val="PLAYING"/>`.
    static func firstAttributeValue(for tag: String, attribute: String = "val", in xml: String) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let escapedAttribute = NSRegularExpression.escapedPattern(for: attribute)
        let pattern = "<(?:\\w+:)?\(escapedTag)\\b[^>]*?\\b\(escapedAttribute)\\s*=\\s*\"([^\"]*)\""

        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
            let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
            let range = Range(match.range(at: 1), in: xml)
        else {
            return nil
        }

        return decodeEntities(String(xml[range]))
    }

    static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func baseURL(from locationURL: URL) -> URL? {
        guard var components = URLComponents(url: locationURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func sanitizeUUID(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "uuid:", with: "", options: [.caseInsensitive])
    }
}

struct SonosTopologyMember {
    var uuid: String
    var name: String
    var locationURL: URL?

    var baseURL: URL? {
        guard let locationURL else { return nil }
        return SonosXML.baseURL(from: locationURL)
    }
}

struct SonosTopologyGroup {
    var id: String
    var coordinatorID: String
    var members: [SonosTopologyMember]
}

enum SonosParsing {
    static func parseDeviceDescription(data: Data, locationURL: URL) -> SonosDeviceModel? {
        let parserDelegate = DeviceDescriptionParser(locationURL: locationURL)
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else { return nil }
        return parserDelegate.device
    }

    static func parseZoneGroupState(xml: String) -> [SonosTopologyGroup] {
        let parserDelegate = ZoneGroupStateParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = parserDelegate
        parser.parse()
        return parserDelegate.groups
    }

    static func parseTrackMetadata(xml: String, baseURL: URL) -> SonosTrackModel? {
        guard xml.nilIfBlank != nil else { return nil }

        let parserDelegate = TrackMetadataParser(baseURL: baseURL)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = parserDelegate
        parser.parse()
        return parserDelegate.track
    }
}

private final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    private let locationURL: URL
    private var currentElement: String?
    private var currentText = ""
    private var roomName = ""
    private var friendlyName = ""
    private var modelName = ""
    private var uuid = ""

    init(locationURL: URL) {
        self.locationURL = locationURL
    }

    var device: SonosDeviceModel? {
        guard
            let baseURL = SonosXML.baseURL(from: locationURL),
            let resolvedUUID = SonosXML.sanitizeUUID(uuid).nilIfBlank
        else {
            return nil
        }

        let resolvedRoomName = roomName.nilIfBlank ?? friendlyName.nilIfBlank ?? baseURL.host ?? "Sonos"
        return SonosDeviceModel(
            uuid: resolvedUUID,
            roomName: resolvedRoomName,
            friendlyName: friendlyName.nilIfBlank ?? resolvedRoomName,
            modelName: modelName.nilIfBlank ?? "Sonos Speaker",
            locationURL: locationURL,
            baseURL: baseURL
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = normalizedName(elementName: elementName, qualifiedName: qName)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let normalized = normalizedName(elementName: elementName, qualifiedName: qName)
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalized {
        case "roomName":
            roomName = value
        case "friendlyName":
            friendlyName = value
        case "modelName":
            modelName = value
        case "UDN":
            uuid = value
        default:
            break
        }

        currentElement = nil
        currentText = ""
    }

    private func normalizedName(elementName: String, qualifiedName: String?) -> String {
        let raw = qualifiedName ?? elementName
        return raw.split(separator: ":").last.map(String.init) ?? raw
    }
}

private final class ZoneGroupStateParser: NSObject, XMLParserDelegate {
    private(set) var groups: [SonosTopologyGroup] = []
    private var currentGroupID = ""
    private var currentCoordinatorID = ""
    private var currentMembers: [SonosTopologyMember] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let normalized = normalizedName(elementName: elementName, qualifiedName: qName)

        if normalized == "ZoneGroup" {
            currentGroupID = attributeDict["ID"] ?? UUID().uuidString
            currentCoordinatorID = SonosXML.sanitizeUUID(attributeDict["Coordinator"] ?? "")
            currentMembers = []
        } else if normalized == "ZoneGroupMember" {
            let member = SonosTopologyMember(
                uuid: SonosXML.sanitizeUUID(attributeDict["UUID"] ?? attributeDict["uuid"] ?? ""),
                name: attributeDict["ZoneName"] ?? attributeDict["zoneName"] ?? "Sonos",
                locationURL: URL(string: attributeDict["Location"] ?? attributeDict["location"] ?? "")
            )
            currentMembers.append(member)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let normalized = normalizedName(elementName: elementName, qualifiedName: qName)

        if normalized == "ZoneGroup", !currentMembers.isEmpty {
            groups.append(
                SonosTopologyGroup(
                    id: currentGroupID,
                    coordinatorID: currentCoordinatorID.nilIfBlank ?? currentMembers.first?.uuid ?? UUID().uuidString,
                    members: currentMembers
                )
            )
            currentGroupID = ""
            currentCoordinatorID = ""
            currentMembers = []
        }
    }

    private func normalizedName(elementName: String, qualifiedName: String?) -> String {
        let raw = qualifiedName ?? elementName
        return raw.split(separator: ":").last.map(String.init) ?? raw
    }
}

private final class TrackMetadataParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var currentElement: String?
    private var currentText = ""
    private var title = ""
    private var artist = ""
    private var album = ""
    private var albumArtPath = ""
    private var streamContent = ""

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    var track: SonosTrackModel? {
        let resolvedTitle = title.nilIfBlank ?? streamContent.nilIfBlank
        guard let resolvedTitle else { return nil }

        let albumArtURL: URL?
        if let albumArtPath = albumArtPath.nilIfBlank {
            albumArtURL = URL(string: albumArtPath, relativeTo: baseURL)?.absoluteURL
        } else {
            albumArtURL = nil
        }

        return SonosTrackModel(
            title: resolvedTitle,
            artist: artist.nilIfBlank,
            album: album.nilIfBlank,
            albumArtURL: albumArtURL
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = normalizedName(elementName: elementName, qualifiedName: qName)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let normalized = normalizedName(elementName: elementName, qualifiedName: qName)
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalized {
        case "title":
            title = value
        case "creator":
            artist = value
        case "album":
            album = value
        case "albumArtURI":
            albumArtPath = value
        case "streamContent":
            streamContent = value
        default:
            break
        }

        currentElement = nil
        currentText = ""
    }

    private func normalizedName(elementName: String, qualifiedName: String?) -> String {
        let raw = qualifiedName ?? elementName
        return raw.split(separator: ":").last.map(String.init) ?? raw
    }
}
