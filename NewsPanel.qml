import QtQuick
import qs.Commons
import qs.Ui

// The popup: today's scoreboard per league, the NYT Cooking articles, and the
// settings form. It is a KeyboardPanel on purpose: Shibumi recognises that
// shape on hosted widgets and re-skins it with its own panel tokens and caret.
//
// Keys: h/l or 1/2 switch tabs, j/k move, Enter opens, r refreshes,
// s toggles settings, Tab moves to the next bar popup, Esc closes.
KeyboardPanel {
  id: panel

  required property var widget

  owner: panel.widget
  open: panel.widget.opened
  focusTarget: keyCatcher
  contentWidth: panel.fittedContentWidth(Style.space(420))
  contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

  readonly property color foreground: panel.widget.foreground
  readonly property color dim: panel.widget.dim
  readonly property color urgent: panel.widget.urgent
  readonly property string fontFamily: panel.widget.fontFamily
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)

  readonly property string tab: widget.panelTab
  property int cursor: -1

  // The rows the cursor walks: games in league order, or cooking articles.
  readonly property var rows: {
    if (tab === "cooking") return panel.widget.cooking
    var out = []
    var leagues = panel.widget.leagueList
    for (var i = 0; i < leagues.length; i++) {
      out = out.concat(panel.widget.games.filter(function(g) { return g.league === leagues[i].id }))
    }
    return out
  }

  onOpenChanged: if (open) {
    cursor = -1
    flick.contentY = 0
  }
  onTabChanged: {
    cursor = -1
    flick.contentY = 0
  }

  function moveCursor(dy) {
    if (rows.length === 0) return
    cursor = cursor < 0 ? (dy > 0 ? 0 : rows.length - 1) : Math.max(0, Math.min(rows.length - 1, cursor + dy))
  }

  function activate(index) {
    var row = rows[index]
    if (!row || !row.link) return
    panel.widget.openLink(row.link)
    panel.widget.close()
  }

  function toggleSettings() {
    panel.widget.settingsOpen = !panel.widget.settingsOpen
    flick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function ensureVisible(item) {
    if (!item) return
    var y = item.mapToItem(column, 0, 0).y
    if (y < flick.contentY) flick.contentY = y
    else if (y + item.height > flick.contentY + flick.height) flick.contentY = y + item.height - flick.height
  }

  // Rows are matched by id rather than object identity, which does not
  // survive the trip through QML var properties reliably.
  function gameIndex(game) {
    if (!game) return -1
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].league === game.league && rows[i].id === game.id) return i
    }
    return -1
  }

  function scoreLine(game) {
    if (game.state === "pre") return game.away.abbr + " @ " + game.home.abbr
    return game.away.abbr + "  " + game.away.score + " – " + game.home.score + "  " + game.home.abbr
  }

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    blocked: panel.widget.settingsOpen && settingsView.editing
    onCloseRequested: panel.widget.settingsOpen ? panel.toggleSettings() : panel.widget.close()
    onTabRequested: function(direction) { panel.widget.switchPanel(direction) }
    onMoveRequested: function(dx, dy) {
      if (panel.widget.settingsOpen) return
      if (dx !== 0) panel.widget.panelTab = dx > 0 ? "cooking" : "scores"
      else panel.moveCursor(dy)
    }
    onActivateRequested: if (!panel.widget.settingsOpen && panel.cursor >= 0) panel.activate(panel.cursor)
    onTextKey: function(text) {
      if (text === "r") panel.widget.refreshNow()
      else if (text === "s") panel.toggleSettings()
      else if (text === "1" && !panel.widget.settingsOpen) panel.widget.panelTab = "scores"
      else if (text === "2" && !panel.widget.settingsOpen) panel.widget.panelTab = "cooking"
    }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      Column {
        id: column
        width: flick.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "News & Scores"
          meta: {
            if (panel.widget.settingsOpen) return "Settings"
            var parts = []
            if (panel.widget.liveCount > 0) parts.push(panel.widget.liveCount + " live")
            if (panel.widget.feed) parts.push("updated " + panel.widget.ago(panel.widget.feed.updatedAt * 1000))
            return parts.join(" · ")
          }
          foreground: panel.foreground
          fontFamily: panel.fontFamily

          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: panel.widget.newspaperGlyph
              color: panel.widget.liveCount > 0 ? panel.urgent : panel.foreground
              font.family: panel.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            Row {
              spacing: Style.spacing.sm

              PanelActionButton {
                iconText: String.fromCodePoint(0xF0450)
                tooltipText: panel.widget.busy ? "Refreshing…" : "Refresh (r)"
                foreground: panel.foreground
                fontFamily: panel.fontFamily
                enabled: !panel.widget.busy
                visible: !panel.widget.settingsOpen
                onClicked: panel.widget.refreshNow()
              }

              PanelActionButton {
                iconText: String.fromCodePoint(panel.widget.settingsOpen ? 0xF0156 : 0xF0493)
                tooltipText: panel.widget.settingsOpen ? "Close settings (Esc)" : "Settings (s)"
                foreground: panel.foreground
                fontFamily: panel.fontFamily
                onClicked: panel.toggleSettings()
              }
            }
          }
        }

        ButtonGroup {
          visible: !panel.widget.settingsOpen
          options: [
            { value: "scores", label: "Scores" },
            { value: "cooking", label: "Cooking" }
          ]
          value: panel.tab
          foreground: panel.foreground
          fontFamily: panel.fontFamily
          focusable: false
          onChanged: function(v) { panel.widget.panelTab = v }
        }

        PanelSeparator {
          foreground: panel.foreground
        }

        SettingsView {
          id: settingsView
          visible: panel.widget.settingsOpen
          width: parent.width
        }

        // ------------------------------------------------------------ scores

        Column {
          visible: !panel.widget.settingsOpen && panel.tab === "scores"
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: panel.tab === "scores" ? panel.widget.leagueList : []

            Column {
              id: leagueBlock
              required property var modelData
              readonly property var leagueGames: panel.widget.games.filter(function(g) { return g.league === leagueBlock.modelData.id })
              width: parent.width
              spacing: Style.space(2)

              PanelSectionHeader {
                text: leagueBlock.modelData.name
                foreground: panel.foreground
                fontFamily: panel.fontFamily
              }

              Text {
                visible: leagueBlock.leagueGames.length === 0
                textFormat: Text.PlainText
                text: leagueBlock.modelData.error ? leagueBlock.modelData.error : "No games today"
                color: leagueBlock.modelData.error ? panel.urgent : panel.dim
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                elide: Text.ElideRight
              }

              Repeater {
                model: leagueBlock.leagueGames

                GameRow {
                  required property var modelData
                  width: leagueBlock.width
                  game: modelData
                }
              }
            }
          }

          Text {
            visible: panel.widget.leagueList.length === 0
            textFormat: Text.PlainText
            text: panel.widget.feed ? "No leagues configured" : "Loading scores…"
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // ----------------------------------------------------------- cooking

        Column {
          visible: !panel.widget.settingsOpen && panel.tab === "cooking"
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: panel.tab === "cooking" ? panel.widget.cooking : []

            CookingRow {
              required property var modelData
              required property int index
              width: parent.width
              article: modelData
              rowIndex: index
            }
          }

          Text {
            visible: panel.widget.cooking.length === 0
            textFormat: Text.PlainText
            text: panel.widget.feed ? "No NYT Cooking articles in the feed" : "Loading…"
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          visible: !panel.widget.settingsOpen && panel.widget.statusText !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: panel.widget.statusText
          color: panel.urgent
          font.family: panel.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component RowSurface: Rectangle {
    id: surface
    property int rowIndex: -1
    property string link: ""
    readonly property bool selected: panel.cursor === rowIndex
    default property alias content: inner.data

    radius: Style.cornerRadius
    color: selected ? panel.selectedFill : (mouse.containsMouse ? panel.hoverFill : "transparent")
    onSelectedChanged: if (selected) panel.ensureVisible(surface)

    Item {
      id: inner
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: surface.link ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: panel.activate(surface.rowIndex)
    }
  }

  component GameRow: RowSurface {
    id: gameRow
    property var game: null
    readonly property bool live: game && game.state === "in"

    rowIndex: panel.gameIndex(game)
    link: game ? game.link : ""
    implicitHeight: Math.max(gameLine.implicitHeight, gameStatus.implicitHeight) + Style.space(10)

    Text {
      id: gameLine
      anchors.left: parent.left
      anchors.right: gameStatus.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: (gameRow.game && gameRow.game.favorite ? "★ " : "") + (gameRow.game ? panel.scoreLine(gameRow.game) : "")
      color: panel.foreground
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
      font.bold: gameRow.live
      elide: Text.ElideRight
    }

    Text {
      id: gameStatus
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: (gameRow.live ? "● " : "") + (gameRow.game ? gameRow.game.detail : "")
      color: gameRow.live ? panel.urgent : panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component CookingRow: RowSurface {
    id: cookingRow
    property var article: null
    readonly property real thumb: Style.space(56)

    link: article ? article.link : ""
    implicitHeight: Math.max(thumb, cookingText.implicitHeight) + Style.space(10)

    Rectangle {
      id: thumbFrame
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: cookingRow.thumb
      height: cookingRow.thumb
      radius: Style.cornerRadius
      color: panel.hoverFill
      clip: true

      Image {
        anchors.fill: parent
        source: cookingRow.article && cookingRow.article.image ? cookingRow.article.image : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: cookingRow.thumb * 2
        sourceSize.height: cookingRow.thumb * 2
      }
    }

    Column {
      id: cookingText
      anchors.left: thumbFrame.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: cookingRow.article ? cookingRow.article.title : ""
        color: panel.foreground
        font.family: panel.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: {
          var a = cookingRow.article
          if (!a) return ""
          var parts = []
          if (a.author) parts.push(a.author)
          if (a.published) parts.push(panel.widget.ago(Date.parse(a.published)))
          return parts.join(" · ")
        }
        color: panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // Every control binds to the live setting and writes back through
  // panel.widget.saveSetting(), so the form holds no state of its own.
  component SettingsView: Column {
    id: view
    readonly property bool editing: leaguesRow.editing || teamsRow.editing

    spacing: Style.space(12)

    PanelSectionHeader {
      text: "Sports"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
    }

    TextRow {
      id: leaguesRow
      width: parent.width
      label: "Leagues (ESPN paths: soccer/eng.1, basketball/nba, football/nfl, hockey/nhl, baseball/mlb, soccer/uefa.champions)"
      placeholder: "soccer/eng.1,basketball/nba"
      current: panel.widget.leagues
      onCommitted: function(v) { panel.widget.saveSetting("leagues", v) }
    }

    TextRow {
      id: teamsRow
      width: parent.width
      label: "Favourite teams (abbreviations or names, e.g. ARS, LAL). Favourites lead the ticker and get alerts."
      placeholder: "ARS,LAL"
      current: panel.widget.teams
      onCommitted: function(v) { panel.widget.saveSetting("teams", v) }
    }

    ChoiceRow {
      width: parent.width
      label: "Alerts"
      options: [
        { value: "off", label: "Off" },
        { value: "favorites", label: "Favourites" },
        { value: "all", label: "All" }
      ]
      value: panel.widget.alerts
      onChanged: function(v) { panel.widget.saveSetting("alerts", v) }
    }

    ChoiceRow {
      width: parent.width
      label: "Clock"
      options: [
        { value: "12", label: "12h" },
        { value: "24", label: "24h" }
      ]
      value: String(panel.widget.hourCycle)
      onChanged: function(v) { panel.widget.saveSetting("hourCycle", parseInt(v, 10)) }
    }

    PanelSectionHeader {
      text: "Ticker"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
    }

    ChoiceRow {
      width: parent.width
      label: "Shows"
      options: [
        { value: "both", label: "Both" },
        { value: "scores", label: "Scores" },
        { value: "cooking", label: "Cooking" }
      ]
      value: panel.widget.tickerMode
      onChanged: function(v) { panel.widget.saveSetting("tickerMode", v) }
    }

    ChoiceRow {
      width: parent.width
      label: "Width"
      options: [
        { value: "160", label: "S" },
        { value: "240", label: "M" },
        { value: "360", label: "L" }
      ]
      value: String(panel.widget.tickerWidth)
      onChanged: function(v) { panel.widget.saveSetting("tickerWidth", parseInt(v, 10)) }
    }

    ChoiceRow {
      width: parent.width
      label: "Speed"
      options: [
        { value: "25", label: "Slow" },
        { value: "40", label: "Normal" },
        { value: "70", label: "Fast" }
      ]
      value: String(panel.widget.tickerSpeed)
      onChanged: function(v) { panel.widget.saveSetting("tickerSpeed", parseInt(v, 10)) }
    }

    Text {
      visible: panel.widget.saveError !== ""
      width: parent.width
      textFormat: Text.PlainText
      text: panel.widget.saveError
      color: panel.urgent
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.spacing.controlGap
      anchors.right: parent.right

      Button {
        text: "Reset to defaults"
        bordered: true
        foreground: panel.foreground
        fontFamily: panel.fontFamily
        onClicked: panel.widget.resetSettings()
      }

      Button {
        text: "Done"
        bordered: true
        selected: true
        foreground: panel.foreground
        fontFamily: panel.fontFamily
        onClicked: panel.toggleSettings()
      }
    }
  }

  component ChoiceRow: Item {
    id: choiceRow
    property string label: ""
    property var options: []
    property string value: ""
    signal changed(string value)

    implicitHeight: Math.max(choiceLabel.implicitHeight, choiceGroup.implicitHeight)

    Text {
      id: choiceLabel
      textFormat: Text.PlainText
      text: choiceRow.label
      color: panel.foreground
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    ButtonGroup {
      id: choiceGroup
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: choiceRow.options
      value: choiceRow.value
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      focusable: false
      onChanged: function(v) { choiceRow.changed(v) }
    }
  }

  // Caption plus a text field. The field mirrors the stored value until the
  // user starts typing, then hands the text back on Enter or focus loss.
  component TextRow: Column {
    id: textRow
    property string label: ""
    property string placeholder: ""
    property string current: ""
    readonly property bool editing: field.activeFocus
    signal committed(string value)

    spacing: Style.space(6)

    onCurrentChanged: if (!field.activeFocus) field.text = current
    Component.onCompleted: field.text = current

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: textRow.label
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    TextField {
      id: field
      width: parent.width
      placeholderText: textRow.placeholder
      foreground: panel.foreground
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
      onEditingFinished: if (text !== textRow.current) textRow.committed(text)
      Keys.onEscapePressed: function(event) {
        text = textRow.current
        focus = false
        event.accepted = true
      }
    }
  }
}
