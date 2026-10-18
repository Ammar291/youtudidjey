"""A tiny solution-shaped program in the required functional style (lint fixture)."""
import functools
import itertools
import json
import os
import subprocess
import sys
from dataclasses import dataclass

B4 = tuple(json.loads(os.environ.get("YUO_B4", "[]")))


@dataclass(frozen=True)
class Song:
    index: int
    query: str


def compose(*fs):
    return functools.reduce(lambda f, g: lambda x: g(f(x)), fs, lambda x: x)


parse_lines = compose(
    lambda text: text.splitlines(),
    lambda lines: map(str.strip, lines),
    lambda lines: filter(lambda l: l and not l.startswith("#"), lines),
    tuple,
)


def songs(text):
    return tuple(itertools.starmap(Song, enumerate(parse_lines(text))))


def blindly4(*args):
    done = subprocess.run([*B4, *args], capture_output=True, text=True, encoding="utf-8")
    return json.loads(done.stdout or "{}")


def main(argv):
    playlist = songs(open(argv[1], encoding="utf-8").read())
    first = next(itertools.islice(itertools.cycle(playlist), 0, None), None)
    print(json.dumps({"first": first.query if first else None, "count": len(playlist)}))


if __name__ == "__main__":
    main(sys.argv)
