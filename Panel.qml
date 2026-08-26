import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.weather"
  property string ipcTarget: "main.weather"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    locationFile.reload()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    root.refresh()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Parsed wttr.in j1 response. Kept on failure so stale data stays visible.
  property var report: null
  property var dailyForecastReport: null
  property string wttrLocation: ""

  // Configured location, read from the weather.json state file (owned by
  // omarchy-weather-location). The query is the wttr.in path segment
  // (coordinates when stored, else the encoded name); empty means IP
  // auto-detect. The watch makes hand edits take effect live.
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string configuredLocation: configuredLocationState.name
  readonly property string locationQuery: Model.wttrLocationQuery(configuredLocationState.name, configuredLocationState.latitude, configuredLocationState.longitude)

  // Keep the previous report visible while the new location loads. The
  // editor remains open with a spinner, so stale data is never presented
  // under the newly configured location label.
  onLocationQueryChanged: {
    if (savingLocation) savingLocationQueryStarted = true
    forecastRetries = 0
    dailyForecastRetries = 0
    forecastProc.running = false
    dailyForecastProc.running = false
    Qt.callLater(refresh)
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configuredLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.configuredLocationState = Model.parseLocationFile("")
  }

  // The first read can race shell startup (observed sporadically), leaving a
  // stored location unhonored until the next file write. One delayed reload
  // self-corrects; if the first read was fine it's a no-op, since identical
  // state doesn't change locationQuery and so triggers no refetch.
  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  property int forecastRetries: 0
  property int dailyForecastRetries: 0

  // Click-to-edit state for the location label.
  property bool editingLocation: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  // Shared hero/bar icon state, updated with each successful weather response.
  property string label: ""

  // wttr's current conditions when available; open-meteo's (bundled with the
  // much faster daily forecast fetch) fill the hero while wttr is in flight.
  readonly property bool hasConfiguredCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude))) && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property var openMeteoCurrent: Model.openMeteoCurrentCondition(dailyForecastReport)
  readonly property var hourlySeries: Model.openMeteoHourlySeries(dailyForecastReport)
  readonly property var moonData: Model.moonInfo(report)
  readonly property var windDirDeg: Model.windDirection(report, dailyForecastReport)
  readonly property var sunTimesData: Model.sunTimes(dailyForecastReport)
  property var aqiReport: null
  readonly property int aqiValue: {
    var v = aqiReport && aqiReport.current ? parseFloat(aqiReport.current.us_aqi) : NaN
    return isNaN(v) ? -1 : Math.round(v)
  }
  readonly property bool hasPollen: {
    if (!aqiReport || !aqiReport.current) return false
    var c = aqiReport.current
    return [c.grass_pollen, c.birch_pollen, c.ragweed_pollen].some(function(v) { return v !== null && v !== undefined })
  }
  property var activeAlerts: []
  readonly property var uvIndex: {
    var daily = dailyForecastReport && dailyForecastReport.daily
    if (!daily || !daily.uv_index_max || !daily.uv_index_max.length) return null
    return daily.uv_index_max[0]
  }
  readonly property int pressure: {
    var c = dailyForecastReport && dailyForecastReport.current
    if (!c || c.surface_pressure === undefined) return -1
    return Math.round(c.surface_pressure)
  }
  readonly property var current: (hasConfiguredCoordinates && openMeteoCurrent) ? openMeteoCurrent : ((report && report.current_condition && report.current_condition[0]) ? report.current_condition[0] : openMeteoCurrent)
  readonly property var areaInfo: report && report.nearest_area && report.nearest_area[0] ? report.nearest_area[0] : null
  readonly property var forecastDays: buildForecastDays()
  readonly property string reportCountry: areaInfo && areaInfo.country && areaInfo.country[0] ? areaInfo.country[0].value : ""

  readonly property bool useImperial: Model.shouldUseImperial(setting("unit", ""), Qt.locale().name, reportCountry)

  // Auto-refresh interval in minutes; clamped to a sane minimum.
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 15), 10) || 15)

  readonly property string reportLocation:  configuredLocation || wttrLocation || (areaInfo && areaInfo.areaName && areaInfo.areaName[0] ? areaInfo.areaName[0].value : "")
  readonly property string reportTempNum:   current ? String(useImperial ? current.temp_F : current.temp_C) : ""
  readonly property string tempUnit:        "°" + (useImperial ? "F" : "C")
  readonly property string reportFeels:     current ? formatTemp(useImperial ? current.FeelsLikeF : current.FeelsLikeC) : ""
  readonly property string reportWind:      current ? (useImperial ? (current.windspeedMiles + " mph") : (current.windspeedKmph + " km/h")) : ""
  readonly property string reportHumidity:  current ? (current.humidity + "%") : ""

  function refresh() {
    // Each full refresh cycle gets a fresh retry budget, so an earlier
    // exhausted round (e.g. waking with the network still down) doesn't
    // starve retries for the rest of the session.
    forecastRetries = 0
    dailyForecastRetries = 0
    if (!forecastProc.running) forecastProc.running = true
    if (root.locationQuery === "" && !locationProc.running) locationProc.running = true
    // With stored coordinates this fetches open-meteo right away — no need
    // to wait for the slow wttr response. Without them it's a no-op until
    // wttr reports the detected area.
    refreshDailyForecast(null)
  }

  function refreshDailyForecast(sourceReport) {
    if (dailyForecastProc.running) return

    var lat = parseFloat(String(root.configuredLocationState.latitude))
    var lon = parseFloat(String(root.configuredLocationState.longitude))
    if (isNaN(lat) || isNaN(lon)) {
      var area = sourceReport && sourceReport.nearest_area && sourceReport.nearest_area[0] ? sourceReport.nearest_area[0] : root.areaInfo
      if (!area) return
      lat = parseFloat(String(area.latitude || ""))
      lon = parseFloat(String(area.longitude || ""))
    }
    if (isNaN(lat) || isNaN(lon)) return

    // Side fetches that share the same resolved coordinates: air quality
    // (AQI + pollen where available) and NWS active alerts.
    aqiProc.command = ["curl", "-fsS", "--max-time", "6",
      "https://air-quality-api.open-meteo.com/v1/air-quality"
      + "?latitude=" + lat + "&longitude=" + lon
      + "&current=us_aqi,pm2_5,grass_pollen,birch_pollen,ragweed_pollen&timezone=auto"]
    aqiProc.running = true
    alertsProc.command = ["curl", "-fsS", "--max-time", "6",
      "-H", "User-Agent: omarchy-weather",
      "https://api.weather.gov/alerts/active?point=" + lat + "," + lon]
    alertsProc.running = true

    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max"
      + "&hourly=temperature_2m,precipitation_probability"
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day,surface_pressure"
      + "&forecast_days=4"
      + "&timezone=auto"
    dailyForecastProc.command = ["curl", "-fsS", "--max-time", "5", url]
    dailyForecastProc.running = true
  }

  // ---- Location editing. Clicking the location label swaps it for a search
  //      field; picking a geocoded suggestion persists name + coordinates to
  //      the module's shell.json entry. An empty commit returns to auto.
  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = root.configuredLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (location.name === "") {
      clearLocation()
      return
    }
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: location.name,
      latitude: location.latitude,
      longitude: location.longitude
    }
    persistLocation(location.name, location.latitude, location.longitude)
  }

  function clearLocation() {
    persistLocation("", null, null)
    wttrLocation = ""
    cancelEditingLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: suggestion.name,
      latitude: suggestion.latitude,
      longitude: suggestion.longitude
    }
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function finishSavingLocation() {
    if (savingLocation && savingLocationQueryStarted) cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    if (name && latitude !== null && longitude !== null)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name, latitude + "," + longitude]
    else if (name)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name]
    else
      locationSaveProc.command = ["omarchy-weather-location", "--clear"]
    locationSaveProc.running = true
  }

  // Debounced geocoding. Only one curl runs at a time; if the query moved on
  // while a fetch was in flight, the latest query is fetched right after.
  function requestGeocode() {
    var query = locationField.text.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function buildForecastDays() {
    return Model.buildForecastDays(report, dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function openMeteoForecastDays() {
    return Model.openMeteoForecastDays(dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function wttrNextForecastDays() {
    return Model.wttrNextForecastDays(report, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function isFutureForecastDate(dateString) {
    return Model.isFutureForecastDate(dateString, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function roundedTemp(value) {
    return Model.roundedTemp(value)
  }

  function celsiusToFahrenheit(value) {
    return Model.celsiusToFahrenheit(value)
  }

  function formatTemp(value) {
    return Model.formatTemp(value, useImperial)
  }

  function dayName(dateString) {
    return Model.dayName(dateString, function(date) { return Qt.formatDate(date, "dddd") })
  }

  // Bare degree value (no unit letter), used in the forecast row.
  function bareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, useImperial)
  }

  // Representative icon for a forecast day: the hourly entry nearest noon.
  function dayIcon(day) {
    return Model.dayIcon(day)
  }

  function iconForOpenMeteoCode(code) {
    return Model.iconForOpenMeteoCode(code)
  }

  // Mirrors omarchy-weather-icon's wttr.in code → nerd-font glyph mapping.
  function iconForCode(code, night) {
    return Model.iconForCode(code, night)
  }

  Process {
    id: forecastProc
    command: ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + root.locationQuery + "?format=j1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          root.report = parsed
          if (!root.hasConfiguredCoordinates)
            root.label = Model.provisionalCurrentIcon(parsed.current_condition && parsed.current_condition[0], root.label)
          root.forecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "wttr"))
            root.finishSavingLocation()
          // Stored coordinates already drove the fast open-meteo fetch from
          // refresh(); only auto-detect needs the area wttr reported.
          if (isNaN(parseFloat(String(root.configuredLocationState.latitude))))
            root.refreshDailyForecast(parsed)
        } catch (e) {
          // Keep last-good report visible, but try again shortly.
          root.scheduleForecastRetry()
        }
      }
    }
  }

  // wttr.in can be slow or flaky, especially for a location it hasn't
  // cached yet. Retry a few times before leaving it to the refresh timer.
  function scheduleForecastRetry() {
    if (forecastRetries >= 3) return
    forecastRetries++
    forecastRetryTimer.restart()
  }

  Timer {
    id: forecastRetryTimer
    interval: 2500
    onTriggered: if (!forecastProc.running) forecastProc.running = true
  }

  // With configured coordinates this fetch is the only thing that updates the
  // bar icon, so a dropped response (e.g. waking before the network is back)
  // must retry rather than wait out the refresh timer with a stale icon.
  function scheduleDailyForecastRetry() {
    if (dailyForecastRetries >= 3) return
    dailyForecastRetries++
    dailyForecastRetryTimer.restart()
  }

  Timer {
    id: dailyForecastRetryTimer
    interval: 2500
    onTriggered: root.refreshDailyForecast(null)
  }

  Process {
    id: dailyForecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleDailyForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          var parsedCurrent = Model.openMeteoCurrentCondition(parsed)
          root.dailyForecastReport = parsed
          root.label = Model.currentIcon(parsedCurrent, root.label)
          root.dailyForecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "open-meteo"))
            root.finishSavingLocation()
        } catch (e) {
          // Keep last-good daily forecast visible, but try again shortly.
          root.scheduleDailyForecastRetry()
        }
      }
    }
  }

  Process {
    id: aqiProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try { root.aqiReport = JSON.parse(raw) } catch (e) {}
      }
    }
  }

  Process {
    id: alertsProc
    // Non-US coordinates get an error status from NWS; empty parse → no alerts.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.activeAlerts = Model.parseNwsAlerts(String(text || ""))
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.savingLocation) return

      // FileView handles changed locations. Explicitly refresh here too so
      // saving the already-active location cannot strand the spinner.
      locationFile.reload()
      if (!root.savingLocationQueryStarted) {
        root.savingLocationQueryStarted = true
        root.forecastRetries = 0
        root.dailyForecastRetries = 0
        forecastProc.running = false
        dailyForecastProc.running = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: locationProc
    command: ["curl", "-fsS", "--max-time", "4", "https://wttr.in/?format=%l"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        root.wttrLocation = raw.split(",")[0]
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
  }

KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: weatherColumn
          width: weatherScroll.width
          spacing: Style.space(14)

          // ---- Active alerts banner.
          Column {
            visible: root.activeAlerts.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.activeAlerts
              Rectangle {
                required property var modelData
                width: parent.width - Style.space(24)
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Style.cornerRadius
                color: Qt.rgba(0.95, 0.35, 0.35, 0.16)
                border.color: Qt.rgba(0.95, 0.35, 0.35, 0.5)
                border.width: 1
                height: alertCol.implicitHeight + Style.space(12)

                Column {
                  id: alertCol
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(2)

                  Row {
                    spacing: Style.space(6)
                    Text {
                      text: ""  // nf-fa-warning
                      color: "#e57373"
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      text: modelData.event.toUpperCase()
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                  Text {
                    visible: modelData.headline !== ""
                    text: modelData.headline
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                    width: parent.width
                  }
                }
              }
            }
          }

          // ---- Hero row: big icon + temp on the left; location and stats stacked on the right.
Item {
        width: parent.width
        height: Math.max(heroLeft.height, heroRight.height)
        clip: true

Row {
          id: heroLeft
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.right: heroRight.left
          anchors.rightMargin: Style.space(24)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Text {
            id: heroIcon
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 5
            text: root.label || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            // Decorative condition emoji; intentionally larger than the
            // Style.font.* scale's displayLarge (28).
            font.pixelSize: 64
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              id: tempBig
              text: root.reportTempNum || "—"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              // Hero temperature read-out; deliberately oversized, outside
              // the Style.font.* scale.
              font.pixelSize: 48
              font.bold: true
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Math.max(0, heroLeft.width - heroIcon.width - Style.space(24)))
            }
            Text {
              text: root.current ? root.tempUnit : ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.top: tempBig.top
              anchors.topMargin: Style.space(10)
            }
          }
        }

        Column {
          id: heroRight
          width: Math.min(Math.max(weatherStats.implicitWidth, moonRow.implicitWidth + Style.space(150), Style.space(200)), parent.width * 0.62)
          clip: true
          anchors.right: parent.right
          anchors.rightMargin: Style.space(20)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(16)

          Row {
            visible: !root.editingLocation && root.reportLocation !== ""
            spacing: Style.space(6)

            TapHandler {
              onTapped: root.startEditingLocation()
            }
            HoverHandler {
              cursorShape: Qt.PointingHandCursor
            }

            Text {
              text: ""  // nf-fa-map_marker
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: (root.reportLocation || "").toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.letterSpacing: 1
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            visible: root.editingLocation
            spacing: Style.space(6)

            TextField {
              id: locationField
              width: Style.space(190)
              enabled: !root.savingLocation
              placeholderText: "Search city"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily

              onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEditingLocation()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.suggestionIndex > 0) root.suggestionIndex--
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitLocation()
                  event.accepted = true
                }
              }
            }

            // Clear back to IP auto-detect. While a committed location is
            // loading, this same compact affordance becomes a spinner.
            Rectangle {
              width: Style.space(18)
              height: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, Style.cornerRadius)
              color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              Text {
                anchors.centerIn: parent
                text: root.savingLocation ? "󰦖" : "✕"
                font.family: root.bar.fontFamily
                color: Qt.darker(root.bar.foreground, 1.4)
                font.pixelSize: Style.font.bodySmall

                RotationAnimator on rotation {
                  running: root.savingLocation
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                id: clearLocationArea
                anchors.fill: parent
                enabled: !root.savingLocation
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.clearLocation()
              }
            }
          }

          Row {
            id: weatherStats
            visible: !!root.current
            spacing: Style.space(24)

            Column {
              spacing: Style.space(5)
              Text {
                text: "FEELS"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                text: root.reportFeels
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "WIND"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Row {
                spacing: Style.space(4)
                Text {
                  text: "\u25B2"  // ▲
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  rotation: root.windDirDeg !== null ? root.windDirDeg + 180 : 0
                  transformOrigin: Item.Center
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.reportWind
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Column {
              visible: root.aqiValue >= 0
              spacing: Style.space(5)
              Text {
                text: "AQI"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                text: String(root.aqiValue)
                color: Model.aqiColor(root.aqiValue)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            Column {
              visible: root.hasPollen
              spacing: Style.space(5)
              Text {
                text: "POLLEN"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                text: root.aqiReport && root.aqiReport.current ? (root.aqiReport.current.grass_pollen || root.aqiReport.current.birch_pollen || root.aqiReport.current.ragweed_pollen) + " gr/m\u00b3" : "--"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              visible: root.uvIndex !== null
              spacing: Style.space(5)
              Text {
                text: "UV"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                text: String(root.uvIndex)
                color: Model.uvBand(root.uvIndex).color
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            Column {
              visible: root.pressure >= 0
              spacing: Style.space(5)
              Text {
                text: "PRESSURE"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                text: String(root.pressure) + " hPa"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "HUMID"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                text: root.reportHumidity
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }
      }

      // ---- Meteogram: next 24h temperature curve over precipitation bars.
      Column {
        visible: root.hourlySeries !== null
        width: parent.width
        spacing: Style.space(4)

        Text {
          leftPadding: Style.space(16)
          text: "NEXT 24 HOURS"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }

        Item {
          width: parent.width - Style.space(32)
          height: Style.space(130)
          anchors.horizontalCenter: parent.horizontalCenter

          Canvas {
            id: meteogram
            anchors.fill: parent
            antialiasing: true

            property var series: root.hourlySeries
            property bool imperial: root.useImperial
            onSeriesChanged: requestPaint()
            onImperialChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var s = series
              if (!s) return

              var temps = imperial ? s.tempsF : s.tempsC
              var n = temps.length
              if (n < 2) return

              var padTop = 20, padBottom = 22, padX = 6
              var plotW = width - padX * 2
              var plotH = height - padTop - padBottom
              var barAreaH = plotH * 0.3

              // Temperature range with breathing room.
              var minT = Infinity, maxT = -Infinity
              for (var i = 0; i < n; ++i) {
                if (temps[i] === null) continue
                if (temps[i] < minT) minT = temps[i]
                if (temps[i] > maxT) maxT = temps[i]
              }
              if (minT === Infinity) return
              var span = Math.max(maxT - minT, 2)
              minT -= span * 0.15
              maxT += span * 0.25

              function xAt(i) { return padX + plotW * i / (n - 1) }
              function yAt(t) { return padTop + (1 - (t - minT) / (maxT - minT)) * (plotH - barAreaH) }

              var fg = String(root.bar.foreground)
              var accent = String(Color.accent)

              // Precipitation-probability bars anchored to the bottom.
              var barW = plotW / n * 0.5
              ctx.fillStyle = Qt.rgba(0.35, 0.55, 0.95, 0.45)
              for (var b = 0; b < n; ++b) {
                var pct = s.precipPct[b] || 0
                if (pct <= 0) continue
                var bh = barAreaH * pct / 100
                var bx = xAt(b) + (plotW / n - barW) / 2 - barW / 2
                ctx.fillRect(bx, height - padBottom - bh, barW, bh)
              }

              // Soft fill under the temperature curve.
              ctx.beginPath()
              ctx.moveTo(xAt(0), yAt(temps[0]))
              for (var p = 1; p < n; ++p) ctx.lineTo(xAt(p), yAt(temps[p]))
              ctx.lineTo(xAt(n - 1), padTop + plotH - barAreaH)
              ctx.lineTo(xAt(0), padTop + plotH - barAreaH)
              ctx.closePath()
              var grad = ctx.createLinearGradient(0, padTop, 0, padTop + plotH)
              grad.addColorStop(0, Qt.rgba(0.72, 0.55, 0.95, 0.28))
              grad.addColorStop(1, "transparent")
              ctx.fillStyle = grad
              ctx.fill()

              // Temperature curve.
              ctx.beginPath()
              ctx.moveTo(xAt(0), yAt(temps[0]))
              for (var c = 1; c < n; ++c) ctx.lineTo(xAt(c), yAt(temps[c]))
              ctx.strokeStyle = accent
              ctx.lineWidth = 2
              ctx.lineJoin = "round"
              ctx.lineCap = "round"
              ctx.stroke()

              // Labels: hour marks every 4 points, plus max/min temp callouts.
              ctx.fillStyle = fg
              ctx.font = Math.round(Style.font.caption) + "px sans-serif"
              ctx.textAlign = "center"
              for (var hIdx = 0; hIdx < n; hIdx += 4)
                ctx.fillText(s.hours[hIdx], xAt(hIdx), height - padBottom + 14)

              ctx.font = "bold " + Math.round(Style.font.bodySmall) + "px sans-serif"
              ctx.fillStyle = accent
              var maxI = 0, minI = 0
              for (var m = 1; m < n; ++m) {
                if (temps[m] > temps[maxI]) maxI = m
                if (temps[m] < temps[minI]) minI = m
              }
              ctx.fillText(Math.round(temps[maxI]) + "°", xAt(maxI), Math.max(padTop - 4, yAt(temps[maxI]) - 6))
              ctx.fillStyle = fg
              ctx.globalAlpha = 0.7
              ctx.fillText(Math.round(temps[minI]) + "°", xAt(minI), Math.min(padTop + plotH + 10, yAt(temps[minI]) + 14))
              ctx.globalAlpha = 1
            }
          }
        }
      }

      // ---- Geocoding suggestions while the location is being edited.
      Column {
        visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
        width: parent.width
        spacing: 0

        Repeater {
          model: root.locationSuggestions

          Rectangle {
            required property var modelData
            required property int index
            width: parent.width
            height: suggestionRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: index === root.suggestionIndex ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Row {
              id: suggestionRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: modelData.name
                color: index === root.suggestionIndex ? Style.hoverStateColor(root.bar.foreground, Color.accent) : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                visible: text !== ""
                text: modelData.description
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: root.suggestionIndex = index
              onClicked: root.pickSuggestion(modelData)
            }
          }
        }
      }

      Text {
        visible: !root.current
        text: "Fetching forecast…"
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      // ---- Sun & Moon.
      Column {
        visible: root.sunTimesData !== null || root.moonData !== null
        width: parent.width
        spacing: Style.space(8)

        Text {
          leftPadding: Style.space(16)
          text: "SUN & MOON"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }

        Item {
          width: parent.width - Style.space(32)
          height: Style.space(88)
          anchors.horizontalCenter: parent.horizontalCenter

          // Left: sun arc + times.
          Item {
            width: parent.width * 0.55
            height: parent.height
            Canvas {
              id: sunArc
              anchors.fill: parent
              antialiasing: true
              property var st: root.sunTimesData
              onStChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var st = sunArc.st
                if (!st) return
                var cx = width / 2
                var cy = height - 8
                var r = Math.min(width, height * 2) * 0.42
                var fg = String(root.bar.foreground)
                var accent = String(Color.accent)

                // Dashed horizon arc (sunrise→sunset upper semicircle).
                ctx.beginPath()
                ctx.arc(cx, cy, r, Math.PI, 2 * Math.PI, false)
                ctx.setLineDash([6, 6])
                ctx.strokeStyle = fg
                ctx.globalAlpha = 0.25
                ctx.lineWidth = 2
                ctx.stroke()
                ctx.setLineDash([])
                ctx.globalAlpha = 1

                // Sun position along arc.
                var now = new Date()
                var rise = new Date(st.rise)
                var set = new Date(st.set)
                var prog = (now - rise) / (set - rise)
                if (prog < 0) prog = 0
                if (prog > 1) prog = 1
                var ang = Math.PI + prog * Math.PI
                var sx = cx + r * Math.cos(ang)
                var sy = cy + r * Math.sin(ang)

                // Sun dot.
                ctx.beginPath()
                ctx.arc(sx, sy, 6, 0, 2 * Math.PI)
                ctx.fillStyle = accent
                ctx.fill()
                ctx.strokeStyle = fg
                ctx.lineWidth = 1.5
                ctx.stroke()

                // Sunrise/sunset tick marks on arc.
                ctx.fillStyle = fg
                ctx.font = Math.round(Style.font.caption) + "px sans-serif"
                ctx.textAlign = "center"
                ctx.fillText("\u25CF", cx + r, cy - 2) // sunset right
                ctx.fillText("\u25CF", cx - r, cy - 2) // sunrise left
              }
            }
            Row {
              anchors.bottom: parent.bottom
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)
              Column {
                spacing: Style.space(2)
                Text { text: "SUNRISE"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                Text { text: root.sunTimesData ? Qt.formatDateTime(root.sunTimesData.rise, "h:mm A") : "--"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body }
              }
              Column {
                spacing: Style.space(2)
                Text { text: "SUNSET"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                Text { text: root.sunTimesData ? Qt.formatDateTime(root.sunTimesData.set, "h:mm A") : "--"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body }
              }
            }
          }

          // Right: moon graphic + phase + rise/set. Sized by content so the
          // rise/set line never clips; anchored right, left is the sun arc.
          Row {
            id: moonRow
            height: parent.height
            anchors.right: parent.right
            spacing: Style.space(14)

            Canvas {
              id: moonCanvas
              width: Style.space(64)
              height: Style.space(64)
              antialiasing: true
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              property var m: root.moonData
              onMChanged: requestPaint()
              Timer {
                interval: 60000
                running: true
                repeat: true
                triggeredOnStart: false
                onTriggered: moonCanvas.requestPaint()
              }
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var m = moonCanvas.m
                if (!m) return
                var cx = width / 2, cy = height / 2, r = 24
                var frac = Math.max(0, Math.min(1, (m.illumination || 0) / 100))
                var waxing = !!m.waxing
                var fg = String(root.bar.foreground)

                // Dark disc (shadow side).
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI*2); ctx.fillStyle = Qt.rgba(1,1,1,0.12); ctx.fill()

                // Lit region: outer limb semicircle on the lit side, closed
                // by an elliptical terminator. QML Canvas has no ellipse(),
                // so the terminator is a unit arc drawn under a horizontal
                // scale transform. The terminator bulges toward the dark
                // side for gibbous (frac > 0.5) and toward the lit side for
                // crescent (frac < 0.5), which anticlockwise = frac <= 0.5
                // expresses for both waxing and waning.
                var k = Math.cos(Math.PI * frac)  // -1..1
                var rx = Math.max(Math.abs(k) * r, 0.01)
                ctx.beginPath()
                if (waxing) {
                  ctx.arc(cx, cy, r, -Math.PI/2, Math.PI/2, false)
                  ctx.save()
                  ctx.translate(cx, cy)
                  ctx.scale(rx / r, 1)
                  ctx.arc(0, 0, r, Math.PI/2, -Math.PI/2, frac <= 0.5)
                  ctx.restore()
                } else {
                  ctx.arc(cx, cy, r, Math.PI/2, 3*Math.PI/2, false)
                  ctx.save()
                  ctx.translate(cx, cy)
                  ctx.scale(rx / r, 1)
                  ctx.arc(0, 0, r, -Math.PI/2, Math.PI/2, frac <= 0.5)
                  ctx.restore()
                }
                ctx.fillStyle = fg
                ctx.fill()

                // Thin limb outline.
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI*2); ctx.strokeStyle = Qt.rgba(1,1,1,0.3); ctx.lineWidth = 1; ctx.stroke()

                // Horizon line with a dot marking how far the moon has
                // travelled from moonrise (left) toward moonset (right),
                // sharing the sun arc's horizon baseline. No dot while the
                // moon is below the horizon.
                var hy = height - 4
                ctx.beginPath()
                ctx.moveTo(2, hy)
                ctx.lineTo(width - 2, hy)
                ctx.strokeStyle = fg
                ctx.globalAlpha = 0.25
                ctx.lineWidth = 1
                ctx.stroke()
                ctx.globalAlpha = 1

                var prog = Model.moonSkyProgress(m)
                if (prog >= 0) {
                  ctx.beginPath()
                  ctx.arc(4 + prog * (width - 8), hy, 3.5, 0, Math.PI*2)
                  ctx.fillStyle = String(Color.accent)
                  ctx.fill()
                }
              }
            }

            Column {
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 2
              spacing: Style.space(2)
              width: Style.space(190)
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.moonData ? root.moonData.phase.toUpperCase() : ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.moonData ? (root.moonData.illumination + "% \u25CF") : ""
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                visible: root.moonData && (root.moonData.moonrise || root.moonData.moonset)
                text: root.moonData ? ("rise " + (root.moonData.moonrise || "--") + " · set " + (root.moonData.moonset || "--")) : ""
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // ---- Divider between current conditions and forecast.
      Rectangle {
        visible: root.forecastDays.length > 0
        width: parent.width
        height: Style.spacing.hairline
        color: root.bar.foreground
        opacity: 0.12
      }

      // ---- Forecast row: each cell has the day icon left of a day-name + hi/lo column.
      //      Wrapped in an Item so the block of cells can be centered within the popup.
      Item {
        visible: root.forecastDays.length > 0
        width: parent.width
        height: forecastRow.height

        Row {
          id: forecastRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(44)

          Repeater {
            model: root.forecastDays

            Row {
              required property var modelData
              required property int index
              spacing: Style.space(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.dayIcon(modelData)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: root.dayName(modelData.date).toUpperCase()
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Row {
                  spacing: Style.space(6)

                  Text {
                    text: root.bareTempForDay(modelData, "max")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: root.bareTempForDay(modelData, "min")
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  }
  }

}
