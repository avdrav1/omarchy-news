"""Tests for bin/av-news-fetch. Run with: python3 -m unittest discover tests"""

import datetime as dt
import fcntl
import importlib.machinery
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "av-news-fetch")
loader = importlib.machinery.SourceFileLoader("av_news_fetch", SCRIPT)
spec = importlib.util.spec_from_loader("av_news_fetch", loader)
fetcher = importlib.util.module_from_spec(spec)
loader.exec_module(fetcher)

NOW = dt.datetime(2026, 10, 10, 12, 0, tzinfo=dt.timezone.utc).timestamp()
EPL = "soccer/eng.1"
NBA = "basketball/nba"
NFL = "football/nfl"
MLB = "baseball/mlb"


def iso(hours_from_now):
    return dt.datetime.fromtimestamp(NOW + hours_from_now * 3600, dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def event(event_id, away, home, state="pre", score=(0, 0), detail="", start=1.0):
    return {
        "id": event_id,
        "date": iso(start),
        "status": {"type": {"state": state, "shortDetail": detail}},
        "links": [{"href": f"https://espn.test/{event_id}"}],
        "competitions": [{"competitors": [
            {"homeAway": "home", "score": str(score[1]), "team": {"abbreviation": home, "displayName": home + " FC"}},
            {"homeAway": "away", "score": str(score[0]), "team": {"abbreviation": away, "displayName": away + " FC"}},
        ]}],
    }


def board(name, *events):
    return json.dumps({"leagues": [{"name": name, "abbreviation": name}], "events": list(events)})


class FetchCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cache = os.path.join(self.tmp, "cache")
        self.fixtures = os.path.join(self.tmp, "fixtures")
        os.makedirs(self.fixtures)
        self.alerts_log = os.path.join(self.tmp, "alerts.log")
        notify = os.path.join(self.tmp, "notify")
        with open(notify, "w") as fh:
            fh.write(f'#!/bin/sh\nprintf "%s|" "$@" >> {self.alerts_log}\necho >> {self.alerts_log}\n')
        os.chmod(notify, 0o755)
        self.notify = notify
        self.put_feed(fetcher.SECTIONS["cooking"]["default"], "nyt-food.xml")
        self.put_feed(fetcher.SECTIONS["news"]["default"], "nyt-home.xml")
        self.put_feed(fetcher.SECTIONS["business"]["default"], "nyt-home.xml")

    def put_feed(self, url, fixture=None, body=None):
        target = os.path.join(self.fixtures, fetcher.fixture_name(url))
        if fixture:
            shutil.copy(os.path.join(HERE, "fixtures", fixture), target)
        else:
            with open(target, "w") as fh:
                fh.write(body)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def serve(self, path, body):
        name = fetcher.fixture_name(fetcher.ESPN_SCOREBOARD.format(path=path))
        with open(os.path.join(self.fixtures, name), "w") as fh:
            fh.write(body)

    def run_fetch(self, now=NOW, leagues=EPL, teams="ARS", alerts="favorites", extra=()):
        argv = ["--cache-dir", self.cache, "--fixtures", self.fixtures, "--leagues", leagues,
                "--teams", teams, "--alerts", alerts, "--notify-cmd", self.notify, "--now", str(now), *extra]
        self.assertEqual(fetcher.main(argv), 0)
        return self.feed()

    def feed(self):
        with open(os.path.join(self.cache, "feed.json")) as fh:
            return json.load(fh)

    def alerts(self):
        if not os.path.exists(self.alerts_log):
            return []
        with open(self.alerts_log) as fh:
            return [line.split("|")[4] for line in fh.read().splitlines() if line]


ATOM_FEED = """<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <title>Markets</title>
  <entry>
    <title>Stocks close higher</title>
    <link rel="alternate" href="https://markets.test/stocks"/>
    <author><name>Pat Lee</name></author>
    <updated>2026-10-10T09:30:00Z</updated>
    <media:thumbnail url="https://markets.test/stocks.jpg"/>
  </entry>
</feed>
"""


class ArticleTests(FetchCase):
    def test_cooking_keeps_only_nyt_cooking_articles(self):
        self.serve(EPL, board("EPL"))
        cooking = self.run_fetch()["articles"]["cooking"]
        self.assertEqual(len(cooking), 2)
        for item in cooking:
            self.assertTrue(item["link"].startswith("https://cooking.nytimes.com/"))
            self.assertTrue(item["title"])
            self.assertTrue(item["author"])
            self.assertTrue(item["image"].startswith("https://"))
            self.assertIsNotNone(dt.datetime.fromisoformat(item["published"]).tzinfo)

    def test_news_and_business_default_to_nyt_feeds_unfiltered(self):
        self.serve(EPL, board("EPL"))
        feed = self.run_fetch()
        self.assertEqual([len(feed["articles"][s]) for s in ("news", "business")], [2, 2])
        self.assertEqual(len(feed["ticker"]["articles"]["news"]), 2)

    def test_custom_atom_feed_is_fetched_as_soon_as_it_is_configured(self):
        self.serve(EPL, board("EPL"))
        self.run_fetch()
        self.put_feed("https://markets.test/atom", body=ATOM_FEED)
        feed = self.run_fetch(now=NOW + 10, extra=("--business-feed", "https://markets.test/atom"))
        self.assertEqual(feed["articles"]["business"], [{
            "title": "Stocks close higher",
            "link": "https://markets.test/stocks",
            "author": "Pat Lee",
            "published": "2026-10-10T09:30:00+00:00",
            "image": "https://markets.test/stocks.jpg",
        }])

    def test_failed_feed_keeps_its_articles_but_a_new_broken_feed_does_not(self):
        self.serve(EPL, board("EPL"))
        self.run_fetch()
        self.put_feed(fetcher.SECTIONS["news"]["default"], body="<not xml")
        feed = self.run_fetch(now=NOW + 1000)
        self.assertEqual(len(feed["articles"]["news"]), 2)
        self.assertTrue(any(e.startswith("News:") for e in feed["errors"]))
        feed = self.run_fetch(now=NOW + 1100, extra=("--news-feed", "https://missing.test/rss"))
        self.assertEqual(feed["articles"]["news"], [])


class AlertTests(FetchCase):
    def test_goal_and_final_for_favourite(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (0, 0), "10'")))
        self.run_fetch()
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (0, 1), "34'")))
        self.run_fetch(now=NOW + 60)
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "post", (0, 1), "FT")))
        self.run_fetch(now=NOW + 120)
        self.assertEqual(self.alerts(), ["Goal: CHE 0–1 ARS", "Final: CHE 0–1 ARS"])

    def test_first_sight_of_a_game_is_quiet(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "post", (2, 1), "FT")))
        self.run_fetch()
        self.assertEqual(self.alerts(), [])

    def test_favourites_mode_ignores_other_teams(self):
        self.serve(EPL, board("EPL", event("1", "LEE", "MCI", "in", (0, 0), "10'")))
        self.run_fetch()
        self.serve(EPL, board("EPL", event("1", "LEE", "MCI", "in", (1, 0), "20'")))
        self.run_fetch(now=NOW + 60)
        self.assertEqual(self.alerts(), [])

    def test_all_mode_and_basketball_baskets_do_not_alert(self):
        self.serve(NBA, board("NBA", event("9", "BKN", "CHA", "in", (10, 8), "Q1 5:00")))
        self.run_fetch(leagues=NBA, alerts="all")
        self.serve(NBA, board("NBA", event("9", "BKN", "CHA", "in", (12, 8), "Q1 4:30")))
        self.run_fetch(leagues=NBA, alerts="all", now=NOW + 60)
        self.assertEqual(self.alerts(), [])
        self.serve(NBA, board("NBA", event("9", "BKN", "CHA", "post", (99, 101), "Final")))
        self.run_fetch(leagues=NBA, alerts="all", now=NOW + 120)
        self.assertEqual(self.alerts(), ["Final: BKN 99–101 CHA"])

    def test_off_mode_never_alerts(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (0, 0), "10'")))
        self.run_fetch(alerts="off")
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "post", (0, 3), "FT")))
        self.run_fetch(alerts="off", now=NOW + 60)
        self.assertEqual(self.alerts(), [])

    def test_football_alerts_touchdowns_and_field_goals_not_extra_points(self):
        scores = [(0, 0), (0, 6), (0, 7), (3, 7), (10, 7)]
        for minute, score in enumerate(scores):
            self.serve(NFL, board("NFL", event("5", "SEA", "SF", "in", score, f"Q2 {10 - minute}:00")))
            self.run_fetch(leagues=NFL, teams="SF", now=NOW + 60 * minute)
        self.assertEqual(self.alerts(), [
            "Touchdown SF: SEA 0–6 SF",
            "Field goal SEA: SEA 3–7 SF",
            "Touchdown SEA: SEA 10–7 SF",
        ])

    def test_baseball_alerts_lead_changes_and_ties_not_every_run(self):
        scores = [(0, 0), (1, 0), (2, 0), (2, 2), (2, 3), (2, 5)]
        for inning, score in enumerate(scores):
            self.serve(MLB, board("MLB", event("7", "SF", "LAD", "in", score, f"Top {inning + 1}")))
            self.run_fetch(leagues=MLB, teams="SF", now=NOW + 60 * inning)
        self.assertEqual(self.alerts(), [
            "SF take the lead: SF 1–0 LAD",
            "Tied: SF 2–2 LAD",
            "LAD take the lead: SF 2–3 LAD",
        ])


class ScheduleTests(FetchCase):
    def mtime(self):
        return os.stat(os.path.join(self.cache, "feed.json")).st_mtime_ns

    def test_idle_cache_is_not_refetched_within_interval(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "pre")))
        self.run_fetch()
        before = self.mtime()
        shutil.rmtree(self.fixtures)  # Any fetch now would fail loudly.
        self.run_fetch(now=NOW + 200)
        self.assertEqual(self.mtime(), before)

    def test_live_game_uses_short_interval(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (0, 0), "10'")))
        self.run_fetch()
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (1, 0), "12'")))
        self.assertEqual(self.run_fetch(now=NOW + 31)["games"][0]["away"]["score"], "1")

    def test_settings_change_refetches_immediately_without_alerts(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (0, 0), "10'")))
        self.run_fetch()
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (0, 1), "12'")))
        feed = self.run_fetch(now=NOW + 5, teams="ARS,CHE")
        self.assertEqual(feed["games"][0]["home"]["score"], "1")
        self.assertEqual(self.alerts(), [])

    def test_failed_league_keeps_last_good_games(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "pre")))
        self.run_fetch()
        self.serve(EPL, "not json")
        feed = self.run_fetch(now=NOW + 400)
        self.assertEqual([g["id"] for g in feed["games"]], ["1"])
        self.assertTrue(feed["errors"] and feed["errors"][0].startswith(EPL))

    def test_imminent_kickoff_uses_short_interval(self):
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "pre", start=2 / 60)))
        self.run_fetch()
        self.serve(EPL, board("EPL", event("1", "CHE", "ARS", "in", (0, 0), "1'")))
        self.assertEqual(self.run_fetch(now=NOW + 31)["games"][0]["state"], "in")

    def test_concurrent_run_steps_aside(self):
        self.serve(EPL, board("EPL"))
        os.makedirs(self.cache)
        with open(os.path.join(self.cache, "lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(fetcher.main(["--cache-dir", self.cache, "--fixtures", self.fixtures,
                                           "--notify-cmd", ""]), 0)
        self.assertFalse(os.path.exists(os.path.join(self.cache, "feed.json")))


class TickerTests(FetchCase):
    def test_order_is_live_then_recent_finals_then_upcoming_favourites_first(self):
        self.serve(EPL, board(
            "EPL",
            event("old", "AAA", "BBB", "post", (1, 0), "FT", start=-20),
            event("pre-other", "LEE", "MCI", "pre", start=2),
            event("pre-fav", "CHE", "ARS", "pre", start=3),
            event("far", "WOL", "EVE", "pre", start=48),
            event("final", "NEW", "BRE", "post", (2, 2), "FT", start=-3),
            event("live", "TOT", "FUL", "in", (1, 1), "55'"),
        ))
        texts = [item["text"].split(" · ")[0] for item in self.run_fetch()["ticker"]["scores"]]
        self.assertEqual(texts, ["TOT 1–1 FUL", "NEW 2–2 BRE", "CHE @ ARS", "LEE @ MCI"])

    def test_favourites_list_holds_only_favourites_and_looks_a_week_ahead(self):
        self.serve(NFL, board(
            "NFL",
            event("fav-sunday", "IND", "PIT", "pre", start=4 * 24),
            event("other-sunday", "NYG", "DAL", "pre", start=4 * 24),
            event("fav-far", "PIT", "BAL", "pre", start=9 * 24),
            event("other-soon", "KC", "DEN", "pre", start=2),
        ))
        ticker = self.run_fetch(leagues=NFL, teams="PIT")["ticker"]
        self.assertEqual([t["text"].split(" · ")[0] for t in ticker["favorites"]], ["IND @ PIT"])
        self.assertEqual([t["text"].split(" · ")[0] for t in ticker["scores"]], ["IND @ PIT", "KC @ DEN"])


if __name__ == "__main__":
    unittest.main()
