import argparse
import functools
import html
import itertools
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from functools import partial, reduce
from itertools import accumulate, count, cycle, dropwhile, islice, repeat, takewhile
from typing import NamedTuple, Optional


# ---------------------------------------------------------------- data types

class Result(NamedTuple):
    code: int
    out: str
    err: str


class Elem(NamedTuple):
    role: str
    path: str
    title: str
    description: str
    identifier: str
    value: str
    frame: str


class Obs(NamedTuple):
    playing: bool
    ad: bool


class WaitState(NamedTuple):
    obs: Obs
    t: float
    ad_seen: bool
    n: int


class Reading(NamedTuple):
    pos: int
    dur: int
    t: float


class ReadState(NamedTuple):
    reading: Optional[Reading]
    believed: bool
    tries: int


class Started(NamedTuple):
    first_seen: float
    hint: Optional[int]


class Attempt(NamedTuple):
    started: Optional[Started]
    reason: str


class Opened(NamedTuple):
    chosen: Optional[Elem]
    reason: str


@dataclass(frozen=True)
class Job:
    idx: int
    query: str
    max_play: Optional[float]


# ---------------------------------------------------------------- constants

AD_TITLES = frozenset(("Sponsored", "My Ad Center", "Skip", "Skip Ad", "Skip Ads"))
BANNED_WORDS = frozenset((
    "mix", "playlist", "live", "loop", "looped", "hour", "hours", "shorts",
    "reaction", "karaoke", "slowed", "reverb", "8d", "nightcore", "sped",
))
DURATION_UNITS = (
    (re.compile(r"(\d+)\s+hours?\b", re.I), 3600),
    (re.compile(r"(\d+)\s+minutes?\b", re.I), 60),
    (re.compile(r"(\d+)\s+seconds?\b", re.I), 1),
)
TAG_RE = re.compile(r"<(AX\w+)\s([^>]*?)/?>")
ATTR_RE = re.compile(r'(\w+)="([^"]*)"')
CLOCK = r"(?:(\d+) Hours? )?(\d+) Minutes? (\d+) Seconds?"
SLIDER_RE = re.compile(CLOCK + " of " + CLOCK, re.I)
PAUSE_LATENCY = 0.6
END_MARGIN = 3.0
OMNIBOX_TITLE = "Address and search bar"
OMNIBOX_DESCRIPTIONS = ("Address and search bar", "Ask Google or type a URL")


# ---------------------------------------------------------------- helpers (pure)

def compose(*fs):
    return lambda x: reduce(lambda acc, f: f(acc), fs, x)


def pipe(x, *fs):
    return compose(*fs)(x)


first = lambda items, default=None: next(iter(items), default)
keep_line = lambda line: bool(line) and not line.startswith("#")
parse_songs = compose(str.splitlines, partial(map, str.strip), partial(filter, keep_line), tuple)


def safe_json(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def elem_from(role, d):
    g = lambda k: str(d.get(k) or "")
    return Elem(role, g("path"), g("title"), g("description"),
                g("identifier") or g("id"), g("value"), g("frame"))


def parse_json_matches(text):
    data = safe_json(text)
    items = data.get("matches", ()) if isinstance(data, dict) else ()
    return tuple(map(lambda m: elem_from(str(m.get("role", "")), m),
                     filter(lambda m: isinstance(m, dict), items)))


def parse_xml(text):
    attrs = lambda raw: dict(map(lambda a: (a[0], html.unescape(a[1])), ATTR_RE.findall(raw)))
    return tuple(map(lambda m: elem_from(m.group(1), attrs(m.group(2))), TAG_RE.finditer(text)))


def elems_of(res, xml=False):
    if res.code != 0:
        return ()
    return parse_xml(res.out) if xml else parse_json_matches(res.out)


def duration_from_title(title):
    parts = tuple(itertools.chain.from_iterable(map(
        lambda unit: tuple(map(lambda n: int(n) * unit[1], unit[0].findall(title)[-1:])),
        DURATION_UNITS)))
    return sum(parts) if parts else None


def words(text):
    return frozenset(re.findall(r"[\w']+", text.lower()))


def acceptable(query, e):
    length = duration_from_title(e.title)
    banned = (words(e.title) & BANNED_WORDS) - words(query)
    return (e.identifier == "video-title" and "watch?v=" in e.value
            and not banned and length is not None and 60 <= length <= 1500)


def score(query, e):
    return 2 * len(words(query) & words(e.title)) + (1 if "official" in e.title.lower() else 0)


def choose_result(query, elems):
    return max(filter(partial(acceptable, query), elems), key=partial(score, query), default=None)


def is_pause(e):
    return e.title.startswith("Pause") and "button" in e.role.lower()


def is_ad_marker(e):
    return e.title in AD_TITLES or e.description in AD_TITLES


def is_search_box(e):
    role = e.role.lower()
    return e.title == "Search" and any(map(lambda k: k in role, ("combobox", "textfield", "edit")))


def is_search_button(e):
    return e.title == "Search" and "button" in e.role.lower()


def controls_ready(c):
    return c[0] is not None and c[1] is not None


def percent_encode(text):
    safe = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    return "".join(map(lambda b: chr(b) if b in safe else "%{:02X}".format(b),
                       text.encode("utf-8")))


def search_url(query):
    return "https://www.youtube.com/results?search_query=" + percent_encode(query)


def frame_center(frame):
    nums = tuple(map(int, re.findall(r"-?\d+", frame)))
    return (nums[0] + nums[2] // 2, nums[1] + nums[3] // 2) if len(nums) == 4 else (637, 540)


def clock_seconds(groups):
    h, m, s = map(lambda g: int(g or 0), groups)
    return h * 3600 + m * 60 + s


def parse_slider(text):
    m = SLIDER_RE.search(text)
    return None if m is None else (clock_seconds(m.groups()[:3]), clock_seconds(m.groups()[3:]))


def believe(reading, first_seen, hint):
    return (reading is not None
            and reading.dur >= 60
            and (hint is None or abs(reading.dur - hint) <= 3)
            and first_seen - 10 <= reading.t - reading.pos <= first_seen + 60)


def deadline_for(start, dur):
    return start + dur - END_MARGIN - PAUSE_LATENCY


def pick_target(natural, cap):
    return natural if cap is None else min(natural, cap)


def resync(start, dur, r2):
    ok = (r2 is not None and abs(r2.dur - dur) <= 1
          and abs((r2.t - r2.pos) - start) <= 10)
    return r2.t - r2.pos if ok else start


def build_record(kind, idx, song, extra, now):
    return {"t": now, "stage": "exploitation", "source": "solution", "kind": kind,
            "song_index": idx, "song": song, **extra}


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--songs", required=True)
    parser.add_argument("--max-songs", type=int, default=None)
    parser.add_argument("--forever", action="store_true")
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--max-play-seconds", type=float, default=None)
    return parser.parse_args(argv)


# ---------------------------------------------------------------- effects

def b4(*parts):
    prefix = json.loads(os.environ["YUO_B4"])
    pid = os.environ["YUO_CHROME_PID"]
    args = (*parts, "--pid", pid)
    proc = subprocess.run([*prefix, *args], capture_output=True)
    return Result(proc.returncode,
                  proc.stdout.decode("utf-8", errors="replace"),
                  proc.stderr.decode("utf-8", errors="replace"))


def b4_many(arglists):
    with ThreadPoolExecutor(max_workers=4) as pool:
        return tuple(pool.map(lambda a: b4(*a), arglists))


def emit(kind, idx, song, **extra):
    record = build_record(kind, idx, song, extra, time.time())
    with open(os.environ["YUO_EVENTS"], "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def sleep_until(t):
    time.sleep(max(0.0, t - time.time()))


def read_text(path):
    with open(path, encoding="utf-8-sig") as fh:
        return fh.read()


def locate_player():
    res = b4("find", "--identifier", "movie_player", "--depth", "40",
             "--limit", "1", "--format", "xml")
    return first(elems_of(res, xml=True))


def observe():
    player = locate_player()
    if player is None:
        return Obs(False, False)
    ad_calls = tuple(map(
        lambda t: ("find", "--under", player.path, "--depth", "5", "--limit", "10", "--title", t),
        ("Sponsored", "My Ad Center", "Skip")))
    pause_call = ("find", "--role", "button", "--title", "Pause", "--depth", "40", "--limit", "5")
    results = b4_many((*ad_calls, pause_call))
    ads = itertools.chain.from_iterable(map(elems_of, results[:3]))
    return Obs(any(map(is_pause, elems_of(results[3]))), any(map(is_ad_marker, ads)))


def read_once():
    player = locate_player()
    if player is None:
        return None
    cx, cy = frame_center(player.frame)
    b4("activate")
    b4("hover", "--x", str(cx - 40), "--y", str(cy))
    b4("hover", "--x", str(cx), "--y", str(cy))
    time.sleep(0.8)
    res = b4("find", "--title", "Seek slider", "--role", "slider",
             "--under", player.path, "--depth", "8", "--limit", "1")
    t = time.time()
    slider = first(elems_of(res))
    parsed = None if slider is None else parse_slider(slider.value)
    return None if parsed is None else Reading(parsed[0], parsed[1], t)


def fetch_after(query, delay):
    time.sleep(delay)
    res = b4("find", "--role", "link", "--identifier", "video-title",
             "--depth", "40", "--limit", "25")
    return choose_result(query, elems_of(res))


def probe_controls(delay):
    time.sleep(delay)
    found = elems_of(b4("find", "--title", "Search", "--depth", "40", "--limit", "40"))
    return (first(filter(is_search_box, found)),
            first(filter(is_search_button, found)))


def submit_via_page(job, box, button):
    typed = b4("set-value", "--path", box.path, "--value", job.query,
               "--expect-description", "Search")
    if typed.code != 0:
        return "set-value failed: " + typed.err.strip()[:120]
    submitted = b4("press", "--path", button.path, "--expect-description", "Search")
    return "" if submitted.code == 0 else "search submit failed: " + submitted.err.strip()[:120]


def submit_via_omnibox(job):
    bar = first(filter(lambda e: e.title == OMNIBOX_TITLE,
                       elems_of(b4("find", "--title", OMNIBOX_TITLE, "--depth", "40", "--limit", "5"))))
    if bar is None:
        return "search controls not found"
    url = search_url(job.query)
    b4("activate")
    typed = first(filter(lambda r: r.code == 0,
                         map(lambda d: b4("set-value", "--path", bar.path, "--value", url,
                                          "--expect-description", d),
                             OMNIBOX_DESCRIPTIONS)))
    if typed is None:
        return "omnibox set-value failed"
    sent = b4("key", "--key", "return", "--target-path", bar.path, "--require-value", url)
    return "" if sent.code == 0 else "omnibox submit failed: " + sent.err.strip()[:120]


def open_result(job):
    b4("activate")
    box, button = next(
        filter(controls_ready,
               map(probe_controls, itertools.chain((0.0,), repeat(2.0, 4)))),
        (None, None))
    reason = (submit_via_omnibox(job) if (box is None or button is None)
              else submit_via_page(job, box, button))
    if reason:
        return Opened(None, reason)
    chosen = first(filter(lambda c: c is not None,
                          map(partial(fetch_after, job.query), (2.5, 1.5, 2.0, 2.0, 2.0, 3.0))))
    if chosen is None:
        return Opened(None, "no suitable video result")
    pressed = b4("press", "--path", chosen.path,
                 "--expect-description", chosen.description or chosen.title)
    if pressed.code != 0:
        return Opened(None, "opening result failed: " + pressed.err.strip()[:120])
    return Opened(chosen, "")


def wait_step(job, prev, _):
    time.sleep(1.0)
    t0 = time.time()
    obs = observe()
    t = (t0 + time.time()) / 2
    if obs.ad and not prev.ad_seen:
        emit("ad_seen", job.idx, job.query)
    return WaitState(obs, t, prev.ad_seen or obs.ad, prev.n + 1)


def try_open(job, _n):
    opened = open_result(job)
    if opened.chosen is None:
        return Attempt(None, opened.reason)
    stream = accumulate(repeat(None, 90), partial(wait_step, job),
                        initial=WaitState(Obs(False, False), 0.0, False, 0))
    ready = next(dropwhile(lambda w: not (w.obs.playing and not w.obs.ad), stream), None)
    if ready is None:
        return Attempt(None, "playback not detected")
    return Attempt(Started(ready.t, duration_from_title(opened.chosen.title)), "")


def read_step(started, prev, _):
    time.sleep(0.0 if prev.tries == 0 else 3.0)
    r = read_once()
    return ReadState(r, believe(r, started.first_seen, started.hint), prev.tries + 1)


def resync_phase(start, dur, target):
    if target - 15.0 - time.time() < 2.0:
        return start
    sleep_until(target - 15.0)
    return resync(start, dur, read_once())


def try_pause(_):
    res = b4("find", "--role", "button", "--title", "Pause", "--depth", "40", "--limit", "5")
    btn = first(filter(is_pause, elems_of(res)))
    if btn is None:
        return None
    pressed = b4("press", "--path", btn.path, "--expect-description", btn.description or btn.title)
    return time.time() if pressed.code == 0 else None


def play_phase(job, started):
    stream = accumulate(repeat(None, 12), partial(read_step, started),
                        initial=ReadState(None, False, 0))
    good = next(filter(lambda s: s.believed, stream), None)
    reading = None if good is None else good.reading
    start, dur = ((reading.t - reading.pos, reading.dur) if reading is not None
                  else (started.first_seen, started.hint))
    if dur is None:
        emit("step_error", job.idx, job.query, reason="video duration unknown")
        return
    extra = {} if reading is None else {"position": round(reading.pos + time.time() - reading.t, 1)}
    emit("playback_started", job.idx, job.query, **extra)
    natural = deadline_for(start, dur)
    cap = None if job.max_play is None else started.first_seen + job.max_play
    target1 = pick_target(natural, cap)
    start2 = start if (cap is not None and cap < natural) else resync_phase(start, dur, target1)
    sleep_until(pick_target(deadline_for(start2, dur), cap))
    done = next(filter(lambda t: t is not None, map(try_pause, range(3))), None)
    if done is None:
        emit("step_error", job.idx, job.query, reason="pause failed")
        return
    emit("paused", job.idx, job.query, duration=dur, remaining=round(start2 + dur - done, 2))


def play_song(job):
    attempts = accumulate(takewhile(lambda n: n < 3, count()),
                          lambda prev, n: prev if prev.started is not None else try_open(job, n),
                          initial=Attempt(None, "not tried"))
    final = reduce(lambda _, x: x, attempts)
    if final.started is None:
        emit("step_error", job.idx, job.query,
             reason="could not find or play song: " + final.reason)
        return
    play_phase(job, final.started)


def run_song(job):
    emit("song_assigned", job.idx, job.query)
    try:
        play_song(job)
    except Exception as exc:
        emit("step_error", job.idx, job.query, reason="unexpected error: " + str(exc)[:200])


def main(argv):
    args = parse_args(argv)
    songs = parse_songs(read_text(args.songs))
    if not songs:
        return 1
    limit = None if args.forever else args.max_songs
    positions = islice(cycle(range(len(songs))), args.start_index % len(songs), None)
    jobs = map(lambda i: Job(i, songs[i], args.max_play_seconds), islice(positions, limit))
    tuple(map(run_song, jobs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
