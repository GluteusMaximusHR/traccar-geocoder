#pragma once

#include <cstdint>
#include <cstring>

// Direct per-country mapping of OSM admin_level / place tag to one of our
// fixed output fields. Derived from Nominatim's settings/address-levels.json
// but flattened: we only care about country/state/county/city/suburb/postcode,
// so anything Nominatim treats as an intermediate level is just ignored here.

namespace address_levels {

enum class Semantic : uint8_t {
    None     = 0,
    Country  = 1,
    State    = 2,
    County   = 3,
    City     = 4,
    Suburb   = 5,
    Postcode = 6,
};

struct LevelEntry {
    uint8_t admin_level;
    Semantic semantic;
};

struct PlaceEntry {
    const char* place_value;
    Semantic polygon_semantic; // when boundary=place + place=X
    Semantic node_semantic;    // when place=X is on a node
};

struct CountryRules {
    const char* country_code;  // lowercase ISO 3166-1 alpha-2, "" for default
    const LevelEntry* admin;
    size_t admin_count;
};

// --- Default admin_level mapping (used when no country override matches) ---
static const LevelEntry kDefaultAdmin[] = {
    {2,  Semantic::Country},
    {4,  Semantic::State},
    {6,  Semantic::County},
    {8,  Semantic::City},
    {9,  Semantic::Suburb},
    {10, Semantic::Suburb},
};

// --- Country overrides ---
// Most countries use the default. Only list deltas when OSM tags admin_level
// differently. Each table is the complete mapping for that country (not
// merged with defaults).

static const LevelEntry kAuAdmin[] = {
    {2, Semantic::Country},
    {4, Semantic::State},
    {6, Semantic::County},   // Local Government Area
    {9, Semantic::Suburb},   // suburb (Lyndhurst etc.)
};

static const LevelEntry kBrAdmin[] = {
    {2, Semantic::Country},
    {4, Semantic::State},
    // 3 = macroregion, 5 = mesoregion, 7 = immediate region: ignored
    {6, Semantic::County},
    {8, Semantic::City},     // município
};

static const LevelEntry kCzAdmin[] = {
    {2,  Semantic::Country},
    {4,  Semantic::State},   // kraj
    {7,  Semantic::County},  // okres
    {10, Semantic::City},    // city
};

static const LevelEntry kDeAdmin[] = {
    {2,  Semantic::Country},
    {4,  Semantic::State},
    {6,  Semantic::County},  // Regierungsbezirk
    {8,  Semantic::City},
    {10, Semantic::Suburb},
};

static const LevelEntry kBeAdmin[] = {
    {2, Semantic::Country},
    {4, Semantic::State},    // region
    {6, Semantic::County},   // province
    {8, Semantic::City},
};

static const LevelEntry kNlAdmin[] = {
    {2,  Semantic::Country},
    {4,  Semantic::State},   // province
    {8,  Semantic::City},
    {10, Semantic::Suburb},
};

static const LevelEntry kEsAdmin[] = {
    {2, Semantic::Country},
    {4, Semantic::State},    // autonomous community
    {6, Semantic::County},   // province
    {8, Semantic::City},     // municipality
};

static const LevelEntry kIdAdmin[] = {
    {2, Semantic::Country},
    {4, Semantic::State},    // province
    {5, Semantic::County},   // kabupaten / kota
    {6, Semantic::City},
    {7, Semantic::Suburb},
};

static const LevelEntry kRuAdmin[] = {
    {2, Semantic::Country},
    {4, Semantic::State},    // federal subject
    {6, Semantic::County},
    {8, Semantic::City},
};

static const LevelEntry kJpAdmin[] = {
    {2,  Semantic::Country},
    {4,  Semantic::State},   // prefecture
    {7,  Semantic::County},
    {8,  Semantic::City},
};

static const LevelEntry kNordicAdmin[] = {  // Sweden, Norway
    {2, Semantic::Country},
    {3, Semantic::State},    // county/fylke
    {4, Semantic::City},     // municipality
};

static const LevelEntry kSaAdmin[] = {
    {2, Semantic::Country},
    {4, Semantic::State},    // province
};

static const CountryRules kCountryRules[] = {
    {"au", kAuAdmin,     sizeof(kAuAdmin)/sizeof(LevelEntry)},
    {"br", kBrAdmin,     sizeof(kBrAdmin)/sizeof(LevelEntry)},
    {"cz", kCzAdmin,     sizeof(kCzAdmin)/sizeof(LevelEntry)},
    {"de", kDeAdmin,     sizeof(kDeAdmin)/sizeof(LevelEntry)},
    {"be", kBeAdmin,     sizeof(kBeAdmin)/sizeof(LevelEntry)},
    {"nl", kNlAdmin,     sizeof(kNlAdmin)/sizeof(LevelEntry)},
    {"es", kEsAdmin,     sizeof(kEsAdmin)/sizeof(LevelEntry)},
    {"id", kIdAdmin,     sizeof(kIdAdmin)/sizeof(LevelEntry)},
    {"ru", kRuAdmin,     sizeof(kRuAdmin)/sizeof(LevelEntry)},
    {"jp", kJpAdmin,     sizeof(kJpAdmin)/sizeof(LevelEntry)},
    {"se", kNordicAdmin, sizeof(kNordicAdmin)/sizeof(LevelEntry)},
    {"no", kNordicAdmin, sizeof(kNordicAdmin)/sizeof(LevelEntry)},
    {"sa", kSaAdmin,     sizeof(kSaAdmin)/sizeof(LevelEntry)},
};

// --- Place tag mapping (country-independent) ---
// Used for both boundary=place + place=X polygons and standalone place=X nodes.
static const PlaceEntry kPlaces[] = {
    {"city",          Semantic::City,    Semantic::City},
    {"town",          Semantic::City,    Semantic::City},
    {"village",       Semantic::City,    Semantic::City},
    {"borough",       Semantic::Suburb,  Semantic::Suburb},
    {"suburb",        Semantic::Suburb,  Semantic::Suburb},
    {"hamlet",        Semantic::None,    Semantic::City},   // hamlet only useful as node fallback
    {"quarter",       Semantic::Suburb,  Semantic::Suburb},
    {"neighbourhood", Semantic::None,    Semantic::None},   // too granular
};

// --- Lookup helpers ---

inline Semantic lookup_admin(const char* country_code, uint8_t admin_level) {
    const LevelEntry* table = kDefaultAdmin;
    size_t count = sizeof(kDefaultAdmin) / sizeof(LevelEntry);

    if (country_code && country_code[0]) {
        char lower[3] = {static_cast<char>(std::tolower(country_code[0])),
                         static_cast<char>(std::tolower(country_code[1])), 0};
        for (const auto& rules : kCountryRules) {
            if (std::strcmp(rules.country_code, lower) == 0) {
                table = rules.admin;
                count = rules.admin_count;
                break;
            }
        }
    }

    for (size_t i = 0; i < count; i++) {
        if (table[i].admin_level == admin_level) return table[i].semantic;
    }
    return Semantic::None;
}

inline Semantic lookup_place(const char* value, bool is_polygon) {
    if (!value) return Semantic::None;
    for (const auto& p : kPlaces) {
        if (std::strcmp(p.place_value, value) == 0) {
            return is_polygon ? p.polygon_semantic : p.node_semantic;
        }
    }
    return Semantic::None;
}

} // namespace address_levels
