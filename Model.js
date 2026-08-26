// weather.json holds {"name": ..., "latitude": ..., "longitude": ...} (see
// omarchy-weather-location, which owns the format). Missing, blank, or
// unparseable means the location is auto-detected from the IP address.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

// wttr.in path segment for a configured location: exact coordinates when
// both are present, the URL-encoded name as a fallback (hand-edited
// weather.loc files may only carry a name), empty for IP auto-detect.
function wttrLocationQuery(location, latitude, longitude) {
  var lat = parseFloat(String(latitude))
  var lon = parseFloat(String(longitude))
  if (!isNaN(lat) && !isNaN(lon)) return lat + "," + lon

  var name = String(location || "").replace(/^\s+|\s+$/g, "")
  return name === "" ? "" : encodeURIComponent(name)
}

// Open-Meteo geocoding response → suggestion rows for the location picker.
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

function locationCommit(text, suggestions, selectedIndex) {
  var name = String(text || "").replace(/^\s+|\s+$/g, "")
  if (name === "") return { name: "", latitude: null, longitude: null }

  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  var suggestion = choices[index]
  if (suggestion) return suggestion

  return { name: name, latitude: null, longitude: null }
}

function isFutureForecastDate(dateString, todayString) {
  if (!dateString) return false
  return String(dateString).slice(0, 10) > String(todayString || "")
}

function roundedTemp(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : String(Math.round(n))
}

function celsiusToFahrenheit(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : (n * 9 / 5) + 32
}

function formatTemp(value, useImperial) {
  if (value === undefined || value === null || value === "") return ""
  return value + "°" + (useImperial ? "F" : "C")
}

function normalizedUnit(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
}

function localeUsesImperial(localeName) {
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name) || /^en[_-]LR($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

function countryUsesImperial(countryName) {
  var country = String(countryName || "")
    .replace(/^\s+|\s+$/g, "")
    .replace(/[._-]+/g, " ")
    .toLowerCase()
  if (!country) return null
  if (country === "us" || country === "usa" || country === "united states" || country === "united states of america") return true
  if (country === "liberia" || country === "myanmar" || country === "burma") return true
  return false
}

function shouldUseImperial(unitOverride, localeName, countryName) {
  var unit = normalizedUnit(unitOverride)
  if (unit === "imperial") return true
  if (unit === "metric") return false

  var countryPreference = countryUsesImperial(countryName)
  if (countryPreference !== null) return countryPreference

  return localeUsesImperial(localeName)
}

function dayName(dateString, formatter) {
  if (!dateString) return ""
  var d = new Date(dateString + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  if (formatter) return formatter(d)
  return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getDay()]
}

function openMeteoForecastDays(dailyForecastReport, todayString) {
  var daily = dailyForecastReport && dailyForecastReport.daily ? dailyForecastReport.daily : null
  if (!daily || !daily.time) return []

  var result = []
  for (var i = 0; i < daily.time.length && result.length < 3; ++i) {
    var date = daily.time[i]
    if (!isFutureForecastDate(date, todayString)) continue

    var maxC = daily.temperature_2m_max ? daily.temperature_2m_max[i] : ""
    var minC = daily.temperature_2m_min ? daily.temperature_2m_min[i] : ""
    result.push({
      date: date,
      maxtempC: roundedTemp(maxC),
      mintempC: roundedTemp(minC),
      maxtempF: roundedTemp(celsiusToFahrenheit(maxC)),
      mintempF: roundedTemp(celsiusToFahrenheit(minC)),
      openMeteoWeatherCode: daily.weather_code ? daily.weather_code[i] : null
    })
  }
  return result
}

// Open-Meteo bundles current conditions with the daily forecast request and
// answers far faster than wttr.in. Normalize them to wttr's
// current_condition shape so the panel can use either source
// interchangeably. Open-Meteo reports metric (°C, km/h).
function openMeteoCurrentCondition(dailyForecastReport) {
  var current = dailyForecastReport && dailyForecastReport.current ? dailyForecastReport.current : null
  if (!current || current.temperature_2m === undefined || current.temperature_2m === null) return null
  return {
    temp_C: roundedTemp(current.temperature_2m),
    temp_F: roundedTemp(celsiusToFahrenheit(current.temperature_2m)),
    FeelsLikeC: roundedTemp(current.apparent_temperature),
    FeelsLikeF: roundedTemp(celsiusToFahrenheit(current.apparent_temperature)),
    windspeedKmph: roundedTemp(current.wind_speed_10m),
    windspeedMiles: roundedTemp(current.wind_speed_10m * 0.621371),
    humidity: roundedTemp(current.relative_humidity_2m),
    openMeteoWeatherCode: current.weather_code,
    isDay: current.is_day
  }
}

// Next-24h hourly series from the Open-Meteo daily fetch (which also requests
// hourly temperature and precipitation probability). Returns null until the
// report carries usable hourly data.
function openMeteoHourlySeries(dailyForecastReport) {
  var h = dailyForecastReport && dailyForecastReport.hourly ? dailyForecastReport.hourly : null
  if (!h || !h.time || !h.temperature_2m) return null

  var now = new Date()
  var nowKey = now.getFullYear() + "-" +
    ("0" + (now.getMonth() + 1)).slice(-2) + "-" +
    ("0" + now.getDate()).slice(-2) + "T" +
    ("0" + now.getHours()).slice(-2)
  var start = -1
  for (var i = 0; i < h.time.length; ++i) {
    if (String(h.time[i]) >= nowKey) { start = i; break }
  }
  if (start < 0) return null

  var out = { hours: [], tempsC: [], tempsF: [], precipPct: [] }
  var count = 0
  for (var j = start; j < h.time.length && count < 24; ++j, ++count) {
    out.hours.push(String(h.time[j]).slice(11, 13))
    var t = parseFloat(h.temperature_2m[j])
    out.tempsC.push(isNaN(t) ? null : t)
    out.tempsF.push(isNaN(t) ? null : celsiusToFahrenheit(t))
    var p = h.precipitation_probability ? parseFloat(h.precipitation_probability[j]) : 0
    out.precipPct.push(isNaN(p) ? 0 : p)
  }
  return count > 1 ? out : null
}

// Moon info from the wttr.in astronomy block (report is already fetched).
function moonInfo(report) {
  var days = report && report.weather ? report.weather : []
  if (!days.length) return null
  var astro = days[0].astronomy && days[0].astronomy[0]
  if (!astro) return null
  var phase = String(astro.moon_phase || astro.moonphase || "").replace(/^\s+|\s+$/g, "")
  return {
    phase: phase,
    illumination: parseInt(String(astro.moon_illumination || "0"), 10) || 0,
    waxing: /Waxing|First Quarter/i.test(phase),
    moonrise: String(astro.moonrise || ""),
    moonset: String(astro.moonset || "")
  }
}

// Fraction of the sky-crossing the moon has completed since moonrise, or -1
// when it is below the horizon or the rise/set strings are missing or
// unparsable. wttr times are "hh:mm AM/PM" wall-clock strings without a date,
// so a moon that rises in the evening and sets past midnight is treated as
// spanning midnight (set < rise means the crossing wraps).
function moonSkyProgress(m) {
  if (!m || !m.moonrise || !m.moonset) return -1
  function parse(t) {
    var mt = String(t).trim().match(/^(\d{1,2}):(\d{2})\s*(AM|PM)?$/i)
    if (!mt) return NaN
    var h = parseInt(mt[1], 10) % 12
    if (mt[3] && mt[3].toUpperCase() === "PM") h += 12
    return h * 60 + parseInt(mt[2], 10)
  }
  var rise = parse(m.moonrise)
  var set = parse(m.moonset)
  if (isNaN(rise) || isNaN(set)) return -1
  var now = new Date()
  var cur = now.getHours() * 60 + now.getMinutes()
  var span = set - rise
  if (span <= 0) span += 24 * 60
  var offset = cur - rise
  if (offset < 0) offset += 24 * 60
  if (offset > span) return -1
  return offset / span
}

// Wind direction in degrees (direction wind comes FROM), preferring
// open-meteo's current block, falling back to wttr.
function windDirection(report, dailyForecastReport) {
  var current = dailyForecastReport && dailyForecastReport.current
  if (current && current.wind_direction_10m !== undefined && current.wind_direction_10m !== null) {
    var d = parseFloat(current.wind_direction_10m)
    if (!isNaN(d)) return d
  }
  var cur = report && report.current_condition && report.current_condition[0]
  if (cur && cur.winddirDegree !== undefined) {
    var w = parseFloat(cur.winddirDegree)
    if (!isNaN(w)) return w
  }
  return null
}

// Today's sunrise/sunset Date objects from the open-meteo daily block.
function sunTimes(dailyForecastReport) {
  var daily = dailyForecastReport && dailyForecastReport.daily
  if (!daily || !daily.sunrise || !daily.sunset || !daily.sunrise.length || !daily.sunset.length) return null
  var rise = new Date(daily.sunrise[0])
  var set = new Date(daily.sunset[0])
  if (isNaN(rise.getTime()) || isNaN(set.getTime())) return null
  return { rise: rise, set: set }
}

// US AQI band → display color.
// UV index band → label + color (0-11+ scale)
function uvBand(value) {
  if (value < 3) return { label: "LOW", color: "#81c784" }
  if (value < 6) return { label: "MODERATE", color: "#ffd54f" }
  if (value < 8) return { label: "HIGH", color: "#ffb74d" }
  if (value < 11) return { label: "VERY HIGH", color: "#e57373" }
  return { label: "EXTREME", color: "#c62828" }
}

function aqiColor(value) {
  if (value <= 50) return "#81c784"
  if (value <= 100) return "#ffd54f"
  if (value <= 150) return "#ffb74d"
  if (value <= 200) return "#e57373"
  if (value <= 300) return "#ba68c8"
  return "#a1887f"
}

function aqiBand(value) {
  if (value <= 50) return "GOOD"
  if (value <= 100) return "MODERATE"
  if (value <= 150) return "UNHEALTHY·SENS"
  if (value <= 200) return "UNHEALTHY"
  if (value <= 300) return "VERY UNHEALTHY"
  return "HAZARDOUS"
}

// NWS active-alerts GeoJSON → compact alert rows (empty outside the US).
function parseNwsAlerts(raw) {
  var out = []
  try {
    var data = JSON.parse(String(raw || "{}"))
    var feats = data.features || []
    for (var i = 0; i < feats.length && out.length < 3; ++i) {
      var p = feats[i] && feats[i].properties
      if (!p || p.status === "Expired" || p.status === "Canceled") continue
      out.push({
        event: String(p.event || "Weather alert"),
        headline: String(p.headline || ""),
        severity: String(p.severity || "")
      })
    }
  } catch (e) {}
  return out
}

function currentIcon(current, fallback) {
  if (!current) return fallback || ""
  if (current.openMeteoWeatherCode !== undefined && current.openMeteoWeatherCode !== null)
    return iconForOpenMeteoCode(current.openMeteoWeatherCode, Number(current.isDay) === 0)
  if (current.weatherCode !== undefined && current.weatherCode !== null)
    return iconForCode(current.weatherCode, false)
  return fallback || ""
}

// wttr.in has no day/night flag. Use its icon only to fill an empty initial
// state, never to replace a day/night-aware icon resolved by Open-Meteo.
function provisionalCurrentIcon(current, resolvedIcon) {
  return resolvedIcon || currentIcon(current, "")
}

function weatherResponseCompletesSave(hasConfiguredCoordinates, source) {
  return hasConfiguredCoordinates ? source === "open-meteo" : source === "wttr"
}

function wttrNextForecastDays(report, todayString) {
  var days = report && report.weather ? report.weather : []
  var result = []
  for (var i = 0; i < days.length && result.length < 3; ++i) {
    if (isFutureForecastDate(days[i].date, todayString)) result.push(days[i])
  }
  return result
}

function buildForecastDays(report, dailyForecastReport, todayString) {
  var days = openMeteoForecastDays(dailyForecastReport, todayString)
  return days.length > 0 ? days : wttrNextForecastDays(report, todayString)
}

function bareTempForDay(day, kind, useImperial) {
  if (!day) return ""
  var v = useImperial
    ? (kind === "max" ? day.maxtempF : day.mintempF)
    : (kind === "max" ? day.maxtempC : day.mintempC)
  if (v === undefined || v === null || v === "") return ""
  return v + "°"
}

function dayIcon(day) {
  if (!day) return ""
  if (day.openMeteoWeatherCode !== undefined && day.openMeteoWeatherCode !== null)
    return iconForOpenMeteoCode(day.openMeteoWeatherCode)
  if (!day.hourly || day.hourly.length === 0) return ""

  var best = day.hourly[0]
  var bestDist = 9999
  for (var i = 0; i < day.hourly.length; ++i) {
    var t = parseInt(String(day.hourly[i].time || "0"), 10)
    var dist = Math.abs(t - 1200)
    if (dist < bestDist) {
      bestDist = dist
      best = day.hourly[i]
    }
  }
  return iconForCode(best.weatherCode, false)
}

function iconForOpenMeteoCode(code, night) {
  var c = parseInt(String(code || "0"), 10)
  if (c === 0) return iconForCode(113, night)
  if (c === 1 || c === 2) return iconForCode(116, night)
  if (c === 3) return iconForCode(119, night)
  if (c === 45 || c === 48) return iconForCode(143, night)
  if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57 || c === 61) return iconForCode(266, night)
  if (c === 63 || c === 65 || c === 66 || c === 67 || c === 80 || c === 81 || c === 82) return iconForCode(308, night)
  if (c === 71 || c === 73 || c === 75 || c === 77 || c === 85 || c === 86) return iconForCode(338, night)
  if (c === 95 || c === 96 || c === 99) return iconForCode(389, night)
  return iconForCode(119, night)
}

function iconForCode(code, night) {
  var c = parseInt(String(code || "0"), 10)
  switch (c) {
    case 113: return night ? "" : ""
    case 116: return night ? "" : ""
    case 119: case 122: return ""
    case 143: case 248: case 260: return night ? "\ue346" : "\ue313"
    case 176: case 263: case 353: return night ? "" : ""
    case 179: case 227: case 230: case 323: case 326: case 368: return night ? "" : ""
    case 182: case 185: case 281: case 284: case 311: case 314:
    case 317: case 320: case 350: case 362: case 365: case 374: case 377: return ""
    case 200: case 386: case 389: case 392: case 395: return ""
    case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359: return ""
    case 329: case 332: case 335: case 338: case 371: return ""
    default: return ""
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocationFile: parseLocationFile,
    wttrLocationQuery: wttrLocationQuery,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    isFutureForecastDate: isFutureForecastDate,
    roundedTemp: roundedTemp,
    celsiusToFahrenheit: celsiusToFahrenheit,
    formatTemp: formatTemp,
    normalizedUnit: normalizedUnit,
    localeUsesImperial: localeUsesImperial,
    countryUsesImperial: countryUsesImperial,
    shouldUseImperial: shouldUseImperial,
    dayName: dayName,
    openMeteoForecastDays: openMeteoForecastDays,
    openMeteoHourlySeries: openMeteoHourlySeries,
    moonInfo: moonInfo,
    moonSkyProgress: moonSkyProgress,
    windDirection: windDirection,
    sunTimes: sunTimes,
    aqiColor: aqiColor,
    aqiBand: aqiBand,
    uvBand: uvBand,
    parseNwsAlerts: parseNwsAlerts,
    openMeteoCurrentCondition: openMeteoCurrentCondition,
    currentIcon: currentIcon,
    provisionalCurrentIcon: provisionalCurrentIcon,
    weatherResponseCompletesSave: weatherResponseCompletesSave,
    wttrNextForecastDays: wttrNextForecastDays,
    buildForecastDays: buildForecastDays,
    bareTempForDay: bareTempForDay,
    dayIcon: dayIcon,
    iconForOpenMeteoCode: iconForOpenMeteoCode,
    iconForCode: iconForCode
  }
}
