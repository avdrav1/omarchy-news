# News & Scores (`av.news`)

An Omarchy shell bar widget, built to sit in the Shibumi bar: a newspaper icon
and a scrolling ticker of live sports scores (ESPN) and headlines, with a popup
holding the full scoreboard, News, Business and NYT Cooking tabs, and settings.

No API keys. Scores come from ESPN's public scoreboard JSON. News and Business
read any RSS or Atom feed and default to NYT Top Stories and NYT Business.
Cooking comes from the NYT Food RSS feed, filtered to `cooking.nytimes.com`
links (NYT Cooking has no feed of its own).

## Install

```bash
./install.sh --enable    # copies into ~/.config/omarchy/plugins/av.news and adds it to the bar (left)
```

After changing the code, re-run `./install.sh` and `omarchy restart shell`: the
shell caches compiled QML, so a running widget keeps its old code until restart.

## Use

| Input | Action |
|---|---|
| Left click | Open / close the popup |
| Right click | Refresh now |
| Middle click on the ticker | Open the game or article under the pointer |
| Hover | Pause the ticker; tooltip lists live games |

In the popup: `h`/`l` or `1`–`4` switch Scores / News / Business / Cooking,
`j`/`k` move, `Enter` opens, `r` refreshes, `s` toggles settings, `Tab` moves to
the next bar popup, `Esc` closes.

IPC: `omarchy-shell av.news toggle|open|close|refresh|settings|text`, and
`omarchy-shell av.news tab scores|news|business|cooking` to open on a tab, e.g. for Hyprland key bindings.

## Settings

Edited from the popup's settings page, or inline on the widget's entry in
`~/.config/omarchy/shell.json` (`omarchy bar set av.news <key> <value>`):

| Key | Default | Meaning |
|---|---|---|
| `leagues` | `soccer/eng.1,basketball/nba` | ESPN `sport/league` paths, e.g. `football/nfl`, `hockey/nhl`, `baseball/mlb`, `soccer/uefa.champions` |
| `teams` | `""` | Favourite team abbreviations or names; they lead the ticker and drive alerts |
| `tickerSources` | `scores,cooking` | Any of `scores`, `news`, `business`, `cooking`, comma-separated |
| `newsFeed` | `""` | RSS or Atom URL for the News tab; empty uses [NYT Top Stories](https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml) |
| `businessFeed` | `""` | RSS or Atom URL for the Business tab; empty uses [NYT Business](https://rss.nytimes.com/services/xml/rss/nyt/Business.xml) |
| `tickerTeams` | `favorites` | `favorites` shows only your teams' games while any is on (live, final in the last 12 h, or within 7 days); otherwise all games. `all` always shows every game |
| `alerts` | `favorites` | `off`, `favorites` or `all` |
| `hourCycle` | `12` | `12` or `24` for kickoff times |
| `tickerWidth` | `240` | Ticker width in px (fixed, so the bar layout stays put) |
| `tickerSpeed` | `40` | Scroll speed in px/s |
| `displayMode` | `full` | `full` (icon + ticker), `icon` or `text` |

## How it works

`bin/av-news-fetch` (Python, standard library) does all fetching and writes
`~/.cache/av.news/feed.json` atomically. The widget runs it every 15 s from
each monitor; a lock and the cache age make all but one run a no-op. Scores
refresh every 30 s while a game is live or about to start, every 5 min
otherwise; article feeds every 15 min, and at once when a feed URL changes.
Failed sources keep their last good data.

Alerts are desktop notifications sent by the helper (`omarchy-notification-send`),
so each event fires once regardless of monitor count:

- **Soccer, hockey:** every goal
- **American football:** touchdowns and field goals (the extra point or two-point try rides along with the touchdown)
- **Baseball:** lead changes and ties, not every run
- **Basketball:** final only (it scores too often for anything else)
- **Every sport:** the final score

Games seen for the first time never alert, so a cold cache or a new league stays quiet.

## Development

```bash
python3 -m unittest discover -s tests     # helper tests (fixtures, no network)
bin/av-news-fetch --force --notify-cmd "" # one live fetch into ~/.cache/av.news
```
