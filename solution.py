"""youtudidjey: play each song read from stdin on YouTube, pause it 3 s before its end."""
import itertools, json, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from typing import NamedTuple, Optional

URL = "https://www.youtube.com"
PLAY_TIMEOUT = 90        # give up on a song after this many seconds
PAUSE_BEFORE_END = 3.0   # the pause must land this long before the end
PRESS_LAG = 0.3          # a press takes about this long to land
CHECK_AHEAD = 20         # re-read the slider this long before the end (ads, buffering)
BAD_WORDS = ("lyrics", "live", "cover", "remix", "karaoke", "reaction", "instrumental", "slowed", "sped", "8d")


class Element(NamedTuple):
    path: str
    title: str
    identifier: str
    value: str
    x: int  # centre of the element on screen
    y: int
    description: str = ""


class Reading(NamedTuple):
    position: int
    duration: int
    clock: float  # when the slider was read


class Snapshot(NamedTuple):
    ad: bool
    skip: Optional[Element]
    reading: Optional[Reading]
    playing: bool  # the control bar offers "Pause"


class Link(NamedTuple):
    element: Element
    seconds: int


# ---- pure core -------------------------------------------------------------------------------

def to_element(m: dict) -> Element:
    pos, size = m.get("position") or {}, m.get("size") or {}
    return Element(m.get("path") or "", m.get("title") or "", m.get("identifier") or "",
                   str(m.get("value") or ""), int(pos.get("x", 0)) + int(size.get("width", 0)) // 2,
                   int(pos.get("y", 0)) + int(size.get("height", 0)) // 2, m.get("description") or "")


def seconds_of(h: Optional[str], m: Optional[str], s: Optional[str]) -> int:
    return int(h or 0) * 3600 + int(m or 0) * 60 + int(s or 0)


def title_seconds(title: str) -> Optional[int]:
    """'... 4 minutes, 8 seconds' -> 248; None when the title ends without a duration (live, mix)."""
    m = re.search(r"(?:(\d+) hours?)?,? ?(?:(\d+) minutes?)?,? ?(?:(\d+) seconds?)?$", title)
    return seconds_of(*m.groups()) or None if m else None


def parse_slider(value: str) -> Optional[tuple[int, int]]:
    """'3 Minutes 47 Seconds of 4 Minutes 7 Seconds' -> (227, 247)."""
    part = r"(?:(\d+) Hours? )?(?:(\d+) Minutes? )?(\d+) Seconds?"
    m = re.fullmatch(part + " of " + part, value.strip())
    return (seconds_of(*m.groups()[:3]), seconds_of(*m.groups()[3:])) if m else None


def score(query: str, link: Link) -> float:
    title = link.element.title.lower()
    words = re.findall(r"\w+", query.lower())
    bonus = 5 * ("official" in title) + 2 * ("audio" in title) + ("video" in title)
    return 10 * sum(w in title for w in words) + bonus - 6 * sum(w in title and w not in words for w in BAD_WORDS)


def choose(query: str, links: tuple[Link, ...]) -> Optional[Link]:
    """The best real song among the results: no mixes, shorts, streams or hour-long loops."""
    ok = tuple(l for l in links if 45 <= l.seconds <= 1200 and not l.element.title.startswith("Mix")
               and "/shorts/" not in l.element.value)
    words = re.findall(r"\w+", query.lower())
    matching = tuple(l for l in ok if sum(w in l.element.title.lower() for w in words) >= max(1, len(words) * 3 // 4))
    return max(matching, key=lambda l: score(query, l), default=None)  # max keeps the first of equal scores


def is_song(s: Snapshot, expected: int) -> bool:
    return (not s.ad and s.playing and s.reading is not None and abs(s.reading.duration - expected) <= 10)


def end_time(r: Reading) -> float:
    return r.clock + r.duration - (r.position + 0.5)  # the slider shows whole seconds, rounded down


def ascii_hint(text: str) -> str:
    return max(re.findall(r"[A-Za-z0-9 ]{4,}", text) or [""], key=len).strip()


# ---- blindly4 --------------------------------------------------------------------------------

def b4(*args: str, timeout: float = 30) -> dict:
    """Runs one blindly4 command and returns its JSON output; errors come back as {"error": …}."""
    try:
        done = subprocess.run(("blindly4", *args), capture_output=True, text=True, encoding="utf-8", timeout=timeout)
        return json.loads(done.stdout or '{"error": "no output"}')
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError) as e:
        return {"error": repr(e)}


def say(word: str) -> None:
    print(word, flush=True)


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def ok(out: dict) -> bool:
    return "error" not in out


def find(pid: int, *args: str, limit: int = 3) -> tuple[Element, ...]:
    out = b4("find", *args, "--limit", str(limit), "--pid", str(pid))
    return tuple(map(to_element, out.get("matches", ()) if isinstance(out, dict) else ()))


def press(pid: int, target: tuple[str, ...], expect: str, *extra: str, timeout: float = 30) -> bool:
    return ok(b4("press", *target, "--expect-description", expect, *extra, "--pid", str(pid), timeout=timeout))


def hover(pid: int, x: int, y: int) -> None:
    if not ok(b4("hover", "--x", str(x), "--y", str(y), "--pid", str(pid))):
        b4("activate", "--pid", str(pid))  # Chrome lost the foreground
        b4("hover", "--x", str(x), "--y", str(y), "--pid", str(pid))


def chrome_pid_from_apps() -> Optional[int]:
    """The profile's Chrome is already running: find its YouTube window among all windows."""
    def walk(node):
        if isinstance(node, dict):
            yield node
            yield from itertools.chain.from_iterable(map(walk, node.values()))
        elif isinstance(node, list):
            yield from itertools.chain.from_iterable(map(walk, node))
    chromes = tuple(d for d in walk(b4("apps")) if d.get("pid") and "chrome" in json.dumps(d).lower())
    best = next((d for d in chromes if "youtube" in json.dumps(d).lower()), next(iter(chromes), None))
    return int(best["pid"]) if best else None


def search_box(pid: int) -> Optional[Element]:
    return next(iter(find(pid, "--title", "Search", "--role", "combobox", "--depth", "40", limit=1)), None)


def open_youtube(profile: str) -> int:
    opened = b4("open", "--url", URL, "--chrome-profile", profile, timeout=60)
    pid = opened.get("pid") or chrome_pid_from_apps()
    if not pid:
        raise SystemExit(f"cannot open or find Chrome: {opened}")
    # Observed: a fresh Chrome often keeps the page out of the accessibility tree until a reload.
    for tick in range(120):
        if search_box(pid):
            return pid
        if tick in (14, 50, 90):
            press(pid, ("--under", "0", "--role", "button", "--title", "Reload"), "Reload")
        time.sleep(0.5)
    log("the search box never appeared")
    return pid


def close_window(pid: int) -> None:
    close = tuple(e for e in find(pid, "--title", "Close", "--role", "button", "--depth", "8") if e.title == "Close")
    if close:
        press(pid, ("--path", close[0].path), "Close")


# ---- steps -----------------------------------------------------------------------------------

def search_for(pid: int, song: str) -> bool:
    box = search_box(pid)
    if box is None or not ok(b4("set-value", "--path", box.path, "--value", song, "--expect-description", "Search", "--pid", str(pid))):
        return False
    scope = box.path.rsplit(".", 2)[0]  # the search form around the box
    buttons = tuple(e for e in find(pid, "--under", scope, "--role", "button", "--title", "Search", "--depth", "4") if e.title == "Search")
    return bool(buttons) and press(pid, ("--path", buttons[0].path), "Search")


def pick_result(pid: int, song: str, timeout: float) -> Optional[Link]:
    """Results show up about 2 s after the search; poll until a fitting one is there."""
    end = time.time() + timeout
    while time.time() < end:
        found = find(pid, "--identifier", "video-title", "--role", "link", "--depth", "40", limit=15)
        pick = choose(song, tuple(Link(e, s) for e in found if (s := title_seconds(e.title))))
        if pick:
            return pick
        time.sleep(0.4)
    return None


def snapshot(pid: int, wiggle) -> Optional[Snapshot]:
    """One look at the player. The pointer must move over it or the slider goes stale."""
    player = next(iter(find(pid, "--identifier", "movie_player", "--depth", "40", limit=1)), None)
    if player is None:
        return None
    hover(pid, player.x + next(wiggle), player.y)
    looks = (("--title", "Sponsored"), ("--title", "Skip", "--role", "button"),
             ("--title", "Seek", "--role", "slider"), ("--title", "Pause", "--role", "button"))
    with ThreadPoolExecutor(len(looks)) as pool:
        ad, skips, sliders, pauses = pool.map(lambda a: find(pid, "--under", player.path, *a), looks)
    clock = time.time()
    skip = next((e for e in skips if e.identifier.startswith("skip-button")), None)
    pos_dur = parse_slider(sliders[0].value) if sliders else None
    return Snapshot(bool(ad), skip, Reading(*pos_dur, clock) if pos_dur else None, bool(pauses))


def wait_playing(pid: int, wiggle, expected: int, deadline: float) -> Optional[Reading]:
    """Skip ads that offer it, wait out the others; return the slider once the song itself plays."""
    while time.time() < deadline:
        snap = snapshot(pid, wiggle)
        if snap and is_song(snap, expected):
            return snap.reading
        if snap and snap.skip:
            press(pid, ("--path", snap.skip.path), "Skip")
        time.sleep(0.3)
    return None


def play(pid: int, wiggle, song: str) -> Optional[Reading]:
    deadline = time.time() + PLAY_TIMEOUT
    while time.time() < deadline:
        link = search_for(pid, song) and pick_result(pid, song, 12)
        if link and press(pid, ("--path", link.element.path), ascii_hint(link.element.description or link.element.title)):
            reading = wait_playing(pid, wiggle, link.seconds, min(deadline, time.time() + 45))
            if reading:
                say("PLAYING")
                return reading
        log(f"retrying {song!r}")
        time.sleep(1)
    log(f"giving up on {song!r}: not playing after {PLAY_TIMEOUT} s")
    return None


def refresh(pid: int, wiggle, old: Reading, expected: int) -> Reading:
    """A fresh reading before the end; ads are skipped or waited out. Stale readings keep the old estimate."""
    stale = 0
    while stale < 4:
        snap = snapshot(pid, wiggle)
        if snap and snap.ad:
            if snap.skip:
                press(pid, ("--path", snap.skip.path), "Skip")
            time.sleep(1)
        elif snap and snap.reading and abs(snap.reading.duration - expected) <= 10:
            advanced = snap.reading.position != old.position or snap.reading.clock - old.clock < 1.5
            if advanced:
                return snap.reading
            stale += 1
        else:
            stale += 1
    log("slider readings are stale: falling back to elapsed time")
    return old


def press_pause(pid: int, at: float) -> bool:
    player = next(iter(find(pid, "--identifier", "movie_player", "--depth", "40", limit=1)), None)
    if player is None:
        return False
    when = ("--at", f"{at:.2f}") if at > time.time() else ()
    return press(pid, ("--under", player.path, "--role", "button", "--title", "Pause"), "Pause", *when, timeout=120 + max(0, at - time.time()))


def is_paused(pid: int) -> bool:
    player = next(iter(find(pid, "--identifier", "movie_player", "--depth", "40", limit=1)), None)
    return player is not None and not find(pid, "--under", player.path, "--role", "button", "--title", "Pause", limit=1)


def pause_before_end(pid: int, wiggle, start: Reading) -> None:
    reading = start
    while (left := end_time(reading) - time.time()) > CHECK_AHEAD + 1:
        time.sleep(left - CHECK_AHEAD)
        reading = refresh(pid, wiggle, reading, start.duration)
    press_pause(pid, end_time(reading) - PAUSE_BEFORE_END - PRESS_LAG)
    for _ in range(3):  # the pause must have taken; if not, press again right away
        if any(time.sleep(0.3) or is_paused(pid) for _ in range(3)):
            break
        log("still playing after the pause: pressing again")
        press_pause(pid, 0)
    say("PAUSED")


def main(profile: str) -> None:
    pid = open_youtube(profile)
    say("READY")
    wiggle = itertools.cycle((-20, 20))
    for song in filter(None, map(str.strip, sys.stdin)):
        started = play(pid, wiggle, song)
        if started is None:
            say("SKIPPED")
        else:
            pause_before_end(pid, wiggle, started)
    close_window(pid)


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--chrome-profile") + 1])
