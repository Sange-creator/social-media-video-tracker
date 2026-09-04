import Foundation

enum CreatorReminderTimeZone: String, CaseIterable, Identifiable {
    // United States
    case usEastern = "America/New_York"
    case usCentral = "America/Chicago"
    case usMountain = "America/Denver"
    case usPacific = "America/Los_Angeles"
    case usAlaska = "America/Anchorage"
    case usHawaii = "Pacific/Honolulu"

    // United Kingdom
    case ukLondon = "Europe/London"

    // Brazil
    case brazilSaoPaulo = "America/Sao_Paulo"
    case brazilManaus = "America/Manaus"

    // Mexico
    case mexicoCity = "America/Mexico_City"
    case mexicoTijuana = "America/Tijuana"
    case mexicoCancun = "America/Cancun"

    // Canada
    case canadaToronto = "America/Toronto"
    case canadaVancouver = "America/Vancouver"

    // European Union (TikTok Creator Rewards Eligible)
    case franceParis = "Europe/Paris"
    case germanyBerlin = "Europe/Berlin"
    case spainMadrid = "Europe/Madrid"
    case italyRome = "Europe/Rome"

    // Asia & Pacific (TikTok Creator Rewards Eligible)
    case japanTokyo = "Asia/Tokyo"
    case koreaSeoul = "Asia/Seoul"
    case australiaSydney = "Australia/Sydney"
    case australiaPerth = "Australia/Perth"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usEastern: "New York"
        case .usCentral: "Chicago"
        case .usMountain: "Denver"
        case .usPacific: "Los Angeles"
        case .usAlaska: "Anchorage"
        case .usHawaii: "Honolulu"
        case .ukLondon: "London"
        case .brazilSaoPaulo: "São Paulo"
        case .brazilManaus: "Manaus"
        case .mexicoCity: "Mexico City"
        case .mexicoTijuana: "Tijuana"
        case .mexicoCancun: "Cancún"
        case .canadaToronto: "Toronto"
        case .canadaVancouver: "Vancouver"
        case .franceParis: "Paris"
        case .germanyBerlin: "Berlin"
        case .spainMadrid: "Madrid"
        case .italyRome: "Rome"
        case .japanTokyo: "Tokyo"
        case .koreaSeoul: "Seoul"
        case .australiaSydney: "Sydney"
        case .australiaPerth: "Perth"
        }
    }

    var country: String {
        switch self {
        case .usEastern, .usCentral, .usMountain, .usPacific, .usAlaska, .usHawaii:
            "United States"
        case .ukLondon:
            "United Kingdom"
        case .brazilSaoPaulo, .brazilManaus:
            "Brazil"
        case .mexicoCity, .mexicoTijuana, .mexicoCancun:
            "Mexico"
        case .canadaToronto, .canadaVancouver:
            "Canada"
        case .franceParis:
            "France"
        case .germanyBerlin:
            "Germany"
        case .spainMadrid:
            "Spain"
        case .italyRome:
            "Italy"
        case .japanTokyo:
            "Japan"
        case .koreaSeoul:
            "South Korea"
        case .australiaSydney, .australiaPerth:
            "Australia"
        }
    }

    var flag: String {
        switch self {
        case .usEastern, .usCentral, .usMountain, .usPacific, .usAlaska, .usHawaii:
            "🇺🇸"
        case .ukLondon:
            "🇬🇧"
        case .brazilSaoPaulo, .brazilManaus:
            "🇧🇷"
        case .mexicoCity, .mexicoTijuana, .mexicoCancun:
            "🇲🇽"
        case .canadaToronto, .canadaVancouver:
            "🇨🇦"
        case .franceParis:
            "🇫🇷"
        case .germanyBerlin:
            "🇩🇪"
        case .spainMadrid:
            "🇪🇸"
        case .italyRome:
            "🇮🇹"
        case .japanTokyo:
            "🇯🇵"
        case .koreaSeoul:
            "🇰🇷"
        case .australiaSydney, .australiaPerth:
            "🇦🇺"
        }
    }

    var shortTitle: String {
        switch self {
        case .usEastern: "ET"
        case .usCentral: "CT"
        case .usMountain: "MT"
        case .usPacific: "PT"
        case .usAlaska: "AKT"
        case .usHawaii: "HT"
        case .ukLondon: "GMT/BST"
        case .brazilSaoPaulo: "BRT"
        case .brazilManaus: "AMT"
        case .mexicoCity: "CST"
        case .mexicoTijuana: "PST"
        case .mexicoCancun: "EST"
        case .canadaToronto: "ET"
        case .canadaVancouver: "PT"
        case .franceParis, .germanyBerlin, .spainMadrid, .italyRome: "CET"
        case .japanTokyo: "JST"
        case .koreaSeoul: "KST"
        case .australiaSydney: "AEST"
        case .australiaPerth: "AWST"
        }
    }

    var displayName: String {
        "\(flag) \(country) – \(title) (\(shortTitle))"
    }

    var timeZone: TimeZone {
        TimeZone(identifier: rawValue) ?? NewYorkSchedule.timeZone
    }

    // Backwards compatibility aliases for existing references
    static var eastern: CreatorReminderTimeZone { .usEastern }
    static var central: CreatorReminderTimeZone { .usCentral }
    static var mountain: CreatorReminderTimeZone { .usMountain }
    static var pacific: CreatorReminderTimeZone { .usPacific }
    static var alaska: CreatorReminderTimeZone { .usAlaska }
    static var hawaii: CreatorReminderTimeZone { .usHawaii }

    struct RegionGroup: Identifiable {
        let name: String
        let flag: String
        let zones: [CreatorReminderTimeZone]
        var id: String { name }
    }

    static var groupedByRegion: [RegionGroup] {
        [
            RegionGroup(name: "United States", flag: "🇺🇸", zones: [.usEastern, .usCentral, .usMountain, .usPacific, .usAlaska, .usHawaii]),
            RegionGroup(name: "United Kingdom", flag: "🇬🇧", zones: [.ukLondon]),
            RegionGroup(name: "Brazil", flag: "🇧🇷", zones: [.brazilSaoPaulo, .brazilManaus]),
            RegionGroup(name: "Mexico", flag: "🇲🇽", zones: [.mexicoCity, .mexicoTijuana, .mexicoCancun]),
            RegionGroup(name: "Canada", flag: "🇨🇦", zones: [.canadaToronto, .canadaVancouver]),
            RegionGroup(name: "European Union", flag: "🇪🇺", zones: [.franceParis, .germanyBerlin, .spainMadrid, .italyRome]),
            RegionGroup(name: "Asia & Pacific", flag: "🌏", zones: [.japanTokyo, .koreaSeoul, .australiaSydney, .australiaPerth])
        ]
    }
}

typealias USReminderTimeZone = CreatorReminderTimeZone

/// Practical starting windows for a broad US audience. Times are shown in
/// New York time and follow daylight-saving changes automatically.
enum NewYorkSchedule {
    struct Slot: Identifiable {
        let number: Int
        let hour: Int
        let minute: Int
        var id: Int { number }

        var label: String {
            label(in: NewYorkSchedule.timeZone)
        }

        func label(in timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = timeZone
            components.hour = hour
            components.minute = minute
            return formatter.string(from: components.date ?? .now)
        }
    }

    static let timeZone = TimeZone(identifier: "America/New_York")!
    static let slots = [
        Slot(number: 1, hour: 9, minute: 0),
        Slot(number: 2, hour: 13, minute: 0),
        Slot(number: 3, hour: 20, minute: 0)
    ]

    static func slot(for number: Int) -> Slot {
        slots[(max(number, 1) - 1) % slots.count]
    }
}
