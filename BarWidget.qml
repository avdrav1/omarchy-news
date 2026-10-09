import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Sports scores and news for the bar: a newspaper icon plus a continuously
// scrolling ticker, and a popup with the full scoreboard, up to five
// configurable article tabs, and the settings. All fetching happens in
// bin/av-news-fetch, which writes one cache file; this widget only runs the
// helper on a timer and draws whatever the cache holds, so every monitor's
// copy shows the same data and alerts fire once.
Panel {
  id: root
  moduleName: "av.news"
  ipcTarget: "av.news"
  manageIpc: false

  // ------------------------------------------------------------------ theme

  readonly property var tokens: bar && "visualTokens" in bar && bar.visualTokens ? bar.visualTokens : null
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color ink: tokens && typeof tokens.widgetContentColor === "function"
    ? tokens.widgetContentColor(settings, root.barForeground)
    : root.barForeground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property string newspaperGlyph: String.fromCodePoint(0xF0395)

  // --------------------------------------------------------------- settings
  // Inline on the widget's shell.json layout entry; see manifest.json.

  // Off drops the Scores tab and the ticker's games, and stops ESPN fetches
  // and alerts (the helper gets no leagues).
  readonly property bool showScores: String(setting("showScores", true)) !== "false"
  readonly property string leagues: String(setting("leagues", "soccer/eng.1,basketball/nba"))
  readonly property string teams: String(setting("teams", ""))
  readonly property var tickerSources: String(setting("tickerSources", "scores,tab1")).split(",")
    .map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
  readonly property string tickerTeams: String(setting("tickerTeams", "favorites"))
  readonly property string alerts: String(setting("alerts", "favorites"))
  readonly property int hourCycle: Number(setting("hourCycle", 12)) === 24 ? 24 : 12
  readonly property int tickerWidth: Math.max(80, Math.min(800, Number(setting("tickerWidth", 240)) || 240))
  readonly property real tickerSpeed: Math.max(10, Math.min(200, Number(setting("tickerSpeed", 40)) || 40))
  readonly property string displayMode: String(setting("displayMode", "full"))

  readonly property var settingDefaults: ({
    showScores: true,
    leagues: "soccer/eng.1,basketball/nba",
    teams: "",
    tickerSources: "scores,tab1",
    tickerTeams: "favorites",
    tab1: "news",
    tab2: "business",
    tab3: "technology",
    tab4: "science",
    tab5: "world",
    tab1Url: "",
    tab2Url: "",
    tab3Url: "",
    tab4Url: "",
    tab5Url: "",
    alerts: "favorites",
    hourCycle: 12,
    tickerWidth: 240,
    tickerSpeed: 40
  })

  // ------------------------------------------------------------------- data

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/av.news"
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/av-news-fetch")).replace(/^file:\/\//, ""))

  property var feed: null
  property string helperError: ""
  property double nowMs: Date.now()
  property bool forceQueued: false

  readonly property var games: feed && feed.games ? feed.games : []
  readonly property var articles: feed && feed.articles ? feed.articles : ({})

  // Categories an article tab can show; the helper fetches whatever URL each
  // tab resolves to.
  readonly property string nytFeedBase: "https://rss.nytimes.com/services/xml/rss/nyt/"
  readonly property var presets: [
    { id: "news", label: "News", name: "NYT Top Stories", url: nytFeedBase + "HomePage.xml" },
    { id: "business", label: "Business", name: "NYT Business", url: nytFeedBase + "Business.xml" },
    { id: "technology", label: "Tech", name: "NYT Technology", url: nytFeedBase + "Technology.xml" },
    { id: "science", label: "Science", name: "NYT Science", url: nytFeedBase + "Science.xml" },
    { id: "world", label: "World", name: "NYT World", url: nytFeedBase + "World.xml" },
    { id: "politics", label: "Politics", name: "NYT Politics", url: nytFeedBase + "Politics.xml" },
    { id: "health", label: "Health", name: "NYT Health", url: nytFeedBase + "Health.xml" },
    { id: "climate", label: "Climate", name: "NYT Climate", url: nytFeedBase + "Climate.xml" },
    { id: "arts", label: "Arts", name: "NYT Arts", url: nytFeedBase + "Arts.xml" },
    { id: "omarchy", label: "Omarchy", name: "Omarchy News", url: "https://omarchy.org/news/rss.xml" }
  ]
  readonly property var slotOptions: presets.map(function(p) { return { value: p.id, label: p.name } })
    .concat([{ value: "custom", label: "Custom RSS/Atom URL" }, { value: "off", label: "Off" }])

  // The five article-tab settings as configured, including ones that are off.
  readonly property var slots: [1, 2, 3, 4, 5].map(function(n) {
    var id = "tab" + n
    return {
      id: id,
      category: String(setting(id, settingDefaults[id])),
      url: String(setting(id + "Url", "")).trim()
    }
  })

  // Article tabs that are on, in display and ticker order. A custom feed is
  // labelled with its own title once fetched.
  readonly property var sections: {
    var titles = feed && feed.titles ? feed.titles : {}
    var out = []
    slots.forEach(function(slot) {
      if (slot.category === "custom") {
        if (slot.url !== "")
          out.push({ id: slot.id, category: "custom", label: shortTitle(titles[slot.id]) || "Custom", url: slot.url })
        return
      }
      var preset = presets.find(function(p) { return p.id === slot.category })
      if (preset)
        out.push({ id: slot.id, category: preset.id, label: preset.label, url: preset.url })
    })
    return out
  }

  // Popup tabs in order. currentTab is the tab actually shown: the chosen one,
  // or the first available if that was turned off ("" when nothing is on).
  readonly property var tabIds: (showScores ? ["scores"] : []).concat(sections.map(function(s) { return s.id }))
  readonly property string currentTab: tabIds.indexOf(panelTab) >= 0 ? panelTab : (tabIds.length > 0 ? tabIds[0] : "")

  // "Hacker News: Front Page" -> "Hacker News", capped to fit a tab chip.
  function shortTitle(title) {
    var short = String(title || "").split(/\s+[-|—>]\s+|:\s+/)[0].trim()
    return short.length > 12 ? short.slice(0, 11) + "…" : short
  }

  readonly property var leagueList: feed && feed.leagues ? feed.leagues : []
  readonly property int liveCount: games.filter(function(g) { return g.state === "in" }).length
  readonly property bool busy: fetchProc.running
  readonly property string statusText: {
    if (helperError !== "") return helperError
    if (feed && feed.errors && feed.errors.length > 0) return feed.errors.join("; ")
    return ""
  }

  readonly property var tickerItems: {
    var out = []
    var ticker = feed && feed.ticker ? feed.ticker : null
    if (!ticker) return out
    if (showScores && tickerSources.indexOf("scores") >= 0) {
      // Favourites only while any of them has a game in the ticker window;
      // otherwise every game, so the ticker never goes blank on an off day.
      var favourites = ticker.favorites || []
      out = out.concat(tickerTeams === "favorites" && favourites.length > 0 ? favourites : (ticker.scores || []))
    }
    var tickerArticles = ticker.articles || {}
    sections.forEach(function(section) {
      if (tickerSources.indexOf(section.id) < 0) return
      out = out.concat((tickerArticles[section.id] || []).map(function(item) {
        return { text: section.label + ": " + item.text, link: item.link, live: false }
      }))
    })
    return out
  }

  readonly property string tooltipText: {
    if (!feed) return statusText !== "" ? "News & Scores: " + statusText : "News & Scores: loading"
    var lines = games.filter(function(g) { return g.state === "in" }).map(function(g) {
      return g.leagueShort + "  " + g.away.abbr + " " + g.away.score + "–" + g.home.score + " " + g.home.abbr + "  " + g.detail
    })
    if (showScores && lines.length === 0) lines.push("No live games")
    lines.push("Updated " + ago(feed.updatedAt * 1000))
    return lines.join("\n")
  }

  function ago(ms) {
    var seconds = Math.max(0, Math.round((nowMs - ms) / 1000))
    if (seconds < 60) return "just now"
    if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
    if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago"
    return Math.floor(seconds / 86400) + "d ago"
  }

  function openLink(url) {
    if (!url) return
    Util.execArgv(["xdg-open", String(url)])
  }

  function applyFeed(text) {
    var raw = String(text || "").trim()
    if (raw === "") return
    try {
      feed = JSON.parse(raw)
      nowMs = Date.now()
    } catch (e) {
      helperError = "unreadable cache file"
    }
  }

  // ---------------------------------------------------------------- fetching

  function runFetch(force) {
    if (fetchProc.running) {
      if (force) forceQueued = true
      return
    }
    var argv = ["python3", helperPath,
      "--leagues", showScores ? leagues : "",
      "--teams", teams,
      "--alerts", alerts,
      "--hour-cycle", String(hourCycle)]
    sections.forEach(function(s) { argv.push("--feed", s.id + "=" + s.url) })
    if (force) argv.push("--force")
    fetchProc.command = argv
    fetchProc.running = true
  }

  function refresh() { runFetch(false) }
  function refreshNow() { runFetch(true) }

  Process {
    id: fetchProc
    running: false

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n")
        root.helperError = lines[lines.length - 1]
      }
    }

    onExited: function(exitCode) {
      if (exitCode === 0) root.helperError = ""
      else if (root.helperError === "") root.helperError = "av-news-fetch failed (exit " + exitCode + ")"
      if (root.forceQueued) {
        root.forceQueued = false
        root.runFetch(true)
      }
    }
  }

  // Cheap: the helper returns at once unless an interval has run out, so the
  // tick only bounds how late a live score can be.
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A settings change refetches straight away (the helper sees the new
  // configuration); debounced so typing a team list doesn't spawn a run per key.
  readonly property string fetchKey: JSON.stringify([showScores ? leagues : "", teams, alerts, hourCycle,
    sections.map(function(s) { return s.id + "=" + s.url })])
  onFetchKeyChanged: fetchDebounce.restart()

  Timer {
    id: fetchDebounce
    interval: 400
    onTriggered: root.refresh()
  }

  FileView {
    id: feedFile
    path: root.cacheDir + "/feed.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyFeed(text())
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // ------------------------------------------------------------- settings io
  //
  // Writes go through the shell's setBarWidget IPC (what `omarchy bar set`
  // calls), so shell.json stays the only store.

  property bool settingsOpen: false
  property string panelTab: "scores"
  property var saveQueue: []
  property string saveError: ""

  function saveSetting(key, value) {
    saveQueue = saveQueue.concat([{ key: key, value: value }])
    pumpSaves()
  }

  function resetSettings() {
    for (var key in settingDefaults) saveSetting(key, settingDefaults[key])
  }

  function pumpSaves() {
    if (saveProc.running || saveQueue.length === 0) return
    var next = saveQueue[0]
    saveQueue = saveQueue.slice(1)
    saveProc.command = ["omarchy-shell", "shell", "setBarWidget", moduleName, next.key, JSON.stringify(next.value), "{}"]
    saveProc.running = true
  }

  Process {
    id: saveProc
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = String(text || "").trim()
        root.saveError = reply === "ok" || reply === "" ? "" : reply
      }
    }

    onExited: function(exitCode) {
      if (exitCode !== 0 && root.saveError === "") root.saveError = "saving failed (omarchy-shell exit " + exitCode + ")"
      root.pumpSaves()
    }
  }

  // IpcHandler rather than the newer ShellIpc wrapper: release builds of the
  // shell don't have ShellIpc, and a missing type stops the whole widget from
  // loading. omarchy-shell falls back to qs ipc for plain handlers.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    // Opens the popup on a tab by slot or category: `omarchy-shell av.news tab technology`.
    function tab(name: string): string {
      if (name !== "scores" || !root.showScores) {
        var section = root.sections.find(function(s) { return s.id === name || s.category === name })
        if (!section) return "unknown tab: " + name
        name = section.id
      }
      root.panelTab = name
      root.open()
      return "ok"
    }
    function settings(): void {
      root.open()
      root.settingsOpen = true
    }
    function text(): string { return root.tickerItems.map(function(i) { return i.text }).join(" | ") }
  }

  // -------------------------------------------------------------------- bar

  // No source picked (or only scores/tabs that are now off): the ticker collapses
  // and the icon stays, even in text mode, so the widget remains clickable.
  readonly property bool tickerEnabled: (showScores && tickerSources.indexOf("scores") >= 0)
    || sections.some(function(s) { return tickerSources.indexOf(s.id) >= 0 })
  readonly property bool showTicker: !vertical && displayMode !== "icon" && tickerEnabled
  readonly property bool showIcon: vertical || displayMode !== "text" || !showTicker

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.feed
    tooltipText: root.tooltipText
    fixedWidth: root.vertical ? -1 : Math.ceil(content.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(content.implicitHeight + button.scaledVerticalPadding * 2) : -1

    onPressed: function(code) {
      if (code === Qt.RightButton) root.refreshNow()
      else if (code === Qt.LeftButton) root.toggle()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showIcon
        textFormat: Text.PlainText
        text: root.newspaperGlyph
        color: root.liveCount > 0 ? root.urgent : root.ink
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: 160 }
        }
      }

      // Fixed width on purpose: Shibumi re-runs its responsive layout when a
      // widget's width changes, so the ticker must not track its text.
      Item {
        id: tickerClip
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showTicker
        width: Style.space(root.tickerWidth)
        height: Math.max(firstCopy.implicitHeight, Style.font.body + Style.space(4))
        clip: true
        layer.enabled: root.showTicker && tickerClip.overflowing
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: tickerMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.5
        }

        readonly property bool overflowing: firstCopy.width > width
        readonly property real loopWidth: firstCopy.width + seamSeparator.width
        property real offset: 0

        onOverflowingChanged: if (!overflowing) offset = 0
        onLoopWidthChanged: if (loopWidth > 0) offset = offset % loopWidth

        FrameAnimation {
          running: root.visible && tickerClip.visible && tickerClip.overflowing
            && !button.tooltipHovered && !root.opened
          onTriggered: tickerClip.offset = (tickerClip.offset + root.tickerSpeed * frameTime) % tickerClip.loopWidth
        }

        Row {
          id: strip
          x: -Math.round(tickerClip.offset)
          anchors.verticalCenter: parent.verticalCenter

          TickerRow { id: firstCopy }
          TickerSeparator { id: seamSeparator; visible: tickerClip.overflowing }
          TickerRow { visible: tickerClip.overflowing }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.tickerItems.length === 0
          textFormat: Text.PlainText
          text: root.feed ? "Nothing on right now" : (root.statusText !== "" ? root.statusText : "Loading…")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering
          elide: Text.ElideRight
          width: tickerClip.width
        }

        // Middle-click opens the story or game under the pointer. Only the
        // middle button is taken, so other clicks reach the WidgetButton.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.MiddleButton
          onClicked: function(mouse) {
            var hit = strip.childAt(mouse.x - strip.x, strip.height / 2)
            if (!hit || !hit.childAt) return
            var item = hit.childAt(mouse.x - strip.x - hit.x, hit.height / 2)
            if (item && item.link) root.openLink(item.link)
          }
        }
      }
    }
  }

  Item {
    id: tickerMask
    width: tickerClip.width
    height: tickerClip.height
    visible: false
    layer.enabled: true

    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "transparent" }
        GradientStop { position: 0.05; color: "white" }
        GradientStop { position: 0.95; color: "white" }
        GradientStop { position: 1.0; color: "transparent" }
      }
    }
  }

  component TickerSeparator: Text {
    textFormat: Text.PlainText
    text: "   •   "
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    renderType: Text.NativeRendering
  }

  // One pass over the ticker items, separated by bullets.
  component TickerRow: Row {
    Repeater {
      model: root.tickerItems

      Row {
        id: entry
        required property var modelData
        required property int index
        readonly property string link: modelData.link || ""

        TickerSeparator { visible: entry.index > 0 }

        Text {
          visible: entry.modelData.live === true
          textFormat: Text.PlainText
          text: "● "
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering
        }

        Text {
          textFormat: Text.PlainText
          text: entry.modelData.text
          color: root.ink
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering
        }
      }
    }
  }

  // ------------------------------------------------------------------ popup

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    settingsOpen = false
    saveError = ""
    refresh()
  }

  NewsPanel {
    widget: root
    anchorItem: button
    bar: root.bar
  }
}
