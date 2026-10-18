import functools
import itertools

f = [lambda: 1, lambda: 2, lambda: 3, lambda: 4, lambda: 5]
total = functools.reduce(lambda a, b: a + b, map(lambda g: g(), f), 0)
evens = list(filter(lambda n: n % 2 == 0, itertools.islice(itertools.count(), 10)))
results = []
count = 0


def record(x):
    global count
    count += 1
    results.append(x)
