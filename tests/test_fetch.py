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
        shutil.copy(os.path.join(HERE, "fixtures", "nyt-food.xml"),
                    os.path.join(self.fixtures, fetcher.fixture_name(fetcher.NYT_FOOD_FEED)))

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


class CookingTests(FetchCase):
    def test_keeps_only_nyt_cooking_articles(self):
        self.serve(EPL, board("EPL"))
        cooking = self.run_fetch()["cooking"]
        self.assertEqual(len(cooking), 2)
        for item in cooking:
            self.assertTrue(item["link"].startswith("https://cooking.nytimes.com/"))
            self.assertTrue(item["title"])
            self.assertTrue(item["author"])
            self.assertTrue(item["image"].startswith("https://"))
            self.assertIsNotNone(dt.datetime.fromisoformat(item["published"]).tzinfo)


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


if __name__ == "__main__":
    unittest.main()
