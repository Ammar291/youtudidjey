# yuotudidjey — exploration vs exploitation

- Exploration run: `results/exploration`
- Exploitation run: `results/exploitation`

**Latency to actual playback** = time from a song being assigned to the moment the song itself started. The independent observer (the same instrument in both stages) first sees the assigned song's page audibly playing with no ad marker, then — with one pointer hover over the player, never a click — reads the player's position and back-dates the start (YouTube can spend several seconds loading the song after an ad). When no fresh reading was possible, the first moment is used. *First audio with no ad marker* is that first moment alone.

## Summary

|  | Exploration (LLM) | Exploitation (solution.py) |
| --- | --- | --- |
| songs assigned | 10 | 10 |
| played / failed | 10 / 0 | 10 / 0 |
| **mean latency to actual playback (s)** | **62.45** | **81.60** |
| median / p90 (s) | 53.07 / 89.97 | 68.71 / 127.03 |
| min / max (s) | 35.39 / 105.83 | 18.88 / 174.85 |
| mean latency to first audio with no ad marker (s) | 58.33 | 72.93 |
| mean ad time before the song (s) | 29.52 | 62.05 |
| mean latency excluding ad time (s) | 32.93 | 19.55 |
| mean blindly4 calls until playback | llm 7.90, driver 5.90 | solution 102.00 |
| mean blindly4 time until playback (s) | 4.93 | 83.76 |
| mean LLM calls until playback | 5.90 | 0.00 |
| LLM share of latency | 69.55 % | 0.00 % |
| mean pause margin (s, target 3) | 3.12 | 2.17 |
| mean blindly4 calls per song (all, by origin) | llm 8.10, driver 17.40 | driver 0.50, solution 124.70 |
| LLM calls in the whole stage | 89 | 0 |

## Per song

| stage | # | song | latency s | est. s | ad s | calls until playback | LLM s | pause margin s | flags |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| exploration | 1 | Daft Punk Get Lucky | 34.70 | 35.39 | 0.00 | llm 6.00, driver 6.00 | 35.91 | 4.21 |  |
| exploration | 2 | Rick Astley Never Gonna Give You Up | 47.03 | 47.29 | 13.59 | llm 7.00, driver 5.00 | 30.72 | 3.34 |  |
| exploration | 3 | Queen Bohemian Rhapsody | 39.05 | 53.07 | 6.06 | llm 7.00, driver 5.00 | 31.54 | 3.24 | assigned late |
| exploration | 4 | a-ha Take On Me | 62.71 | 63.13 | 36.96 | llm 9.00, driver 6.00 | 40.66 | 3.52 | assigned late |
| exploration | 5 | Toto Africa | 40.51 | 40.88 | 12.76 | llm 7.00, driver 4.00 | 25.82 | 2.68 | assigned late |
| exploration | 6 | Michael Jackson Billie Jean | 57.50 | 74.24 | 29.82 | llm 9.00, driver 5.00 | 33.62 | 3.03 | assigned late |
| exploration | 7 | Pharrell Williams Happy | 89.66 | 89.97 | 59.60 | llm 10.00, driver 8.00 | 57.18 | 3.05 | assigned late |
| exploration | 8 | Mark Ronson Uptown Funk | 30.85 | 38.40 | 5.11 | llm 6.00, driver 4.00 | 24.47 | 2.53 | assigned late |
| exploration | 9 | Beyoncé Halo | 75.88 | 76.32 | 50.53 | llm 7.00, driver 7.00 | 46.02 | 3.02 | assigned late |
| exploration | 10 | Coldplay Viva La Vida | 105.46 | 105.83 | 80.77 | llm 11.00, driver 9.00 | 58.12 | 2.60 | assigned late |
| exploitation | 1 | Daft Punk Get Lucky | 20.04 | 18.88 | 0.00 | solution 18.00 | 0.00 | 2.12 |  |
| exploitation | 2 | Rick Astley Never Gonna Give You Up | 35.83 | 68.49 | 29.42 | solution 56.00 | 0.00 | 3.03 |  |
| exploitation | 3 | Queen Bohemian Rhapsody | 69.02 | 70.08 | 61.45 | solution 121.00 | 0.00 | 3.34 |  |
| exploitation | 4 | a-ha Take On Me | 177.64 | 174.85 | 166.16 | solution 247.00 | 0.00 | -0.51 |  |
| exploitation | 5 | Toto Africa | 32.05 | 32.57 | 16.39 | solution 21.00 | 0.00 | 2.58 |  |
| exploitation | 6 | Michael Jackson Billie Jean | 109.38 | 109.47 | 99.43 | solution 92.00 | 0.00 | 2.22 |  |
| exploitation | 7 | Pharrell Williams Happy | 53.41 | 52.25 | 46.54 | solution 96.00 | 0.00 | 2.04 |  |
| exploitation | 8 | Mark Ronson Uptown Funk | 36.89 | 93.65 | 29.29 | solution 52.00 | 0.00 | 2.56 |  |
| exploitation | 9 | Beyoncé Halo | 127.24 | 127.03 | 111.41 | solution 196.00 | 0.00 | 2.30 |  |
| exploitation | 10 | Coldplay Viva La Vida | 67.81 | 68.71 | 60.39 | solution 121.00 | 0.00 | 2.03 |  |

## Command mix (all blindly4 calls)

| origin · command | exploration | exploitation |
| --- | --- | --- |
| driver · activate | 14 | 1 |
| driver · apps | 3 | 3 |
| driver · find | 54 | 31 |
| driver · hover | 26 | 0 |
| driver · inspect | 72 | 2 |
| driver · open | 1 | 1 |
| driver · press | 12 | 1 |
| driver · schema | 6 | 0 |
| llm · find | 49 | 0 |
| llm · press | 22 | 0 |
| llm · set-value | 10 | 0 |
| observer · activate | 19 | 33 |
| observer · find | 1316 | 1601 |
| observer · hover | 38 | 66 |
| observer · inspect | 1697 | 883 |
| solution · activate | 0 | 52 |
| solution · find | 0 | 1072 |
| solution · hover | 0 | 82 |
| solution · key | 0 | 1 |
| solution · press | 0 | 29 |
| solution · set-value | 0 | 11 |

## First song: calls until playback, side by side

### Exploration
```
0.00s [driver] inspect --path 0.1 --pid 5472 → 0
6.29s [llm] find --title Search --role edit --depth 40 --limit 5 --format xml --pid 5472 → 0
6.65s [driver] inspect --path 0.1 --pid 5472 → 0
12.95s [llm] find --title Search --depth 40 --limit 8 --format xml --pid 5472 → 0
13.34s [driver] inspect --path 0.1 --pid 5472 → 0
19.43s [llm] set-value --path 0.1.0.0.1.1.0.1.0.0.0.4.0.0.0 --value Daft Punk Get Lucky --expect-description Search --pid 5472 → 0
19.77s [llm] press --path 0.1.0.0.1.1.0.1.0.0.0.4.0.1 --expect-description Search --pid 5472 → 0
20.06s [driver] inspect --path 0.1 --pid 5472 → 0
26.05s [llm] find --title Get Lucky --role link --depth 40 --limit 8 --format xml --pid 5472 → 0
26.38s [driver] inspect --path 0.1 --pid 5472 → 0
32.79s [llm] press --path 0.1.0.0.1.1.0.1.0.0.2.4.1.0.0 --expect-description Get Lucky (Official Video) --pid 5472 → 0
33.07s [driver] inspect --path 0.1 --pid 5472 → 0
```

### Exploitation
```
0.09s [solution] activate --pid 32888 → 77
1.03s [solution] find --title Search --depth 40 --limit 40 --pid 32888 → 0
3.45s [solution] find --title Search --depth 40 --limit 40 --pid 32888 → 0
5.88s [solution] find --title Search --depth 40 --limit 40 --pid 32888 → 0
8.29s [solution] find --title Search --depth 40 --limit 40 --pid 32888 → 0
10.72s [solution] find --title Search --depth 40 --limit 40 --pid 32888 → 0
11.12s [solution] find --title Address and search bar --depth 40 --limit 5 --pid 32888 → 0
11.53s [solution] activate --pid 32888 → 77
12.47s [solution] set-value --path 0.1.0.0.1.0.0.3.1 --value https://www.youtube.com/results?search_query=Daft%20Punk%20Get%20Lucky --expect-description Address and search bar --pid 32888 → 64
12.83s [solution] set-value --path 0.1.0.0.1.0.0.3.1 --value https://www.youtube.com/results?search_query=Daft%20Punk%20Get%20Lucky --expect-description Ask Google or type a URL --pid 32888 → 0
13.32s [solution] key --key return --target-path 0.1.0.0.1.0.0.3.1 --require-value https://www.youtube.com/results?search_query=Daft%20Punk%20Get%20Lucky --pid 32888 → 0
16.29s [solution] find --role link --identifier video-title --depth 40 --limit 25 --pid 32888 → 0
17.10s [solution] press --path 0.1.0.0.1.1.0.1.0.0.2.3.1.0.0 --expect-description Daft Punk - Get Lucky (Official Video) feat. Pharrell Williams and Nile Rodgers --pid 32888 → 0
18.56s [solution] find --identifier movie_player --depth 40 --limit 1 --format xml --pid 32888 → 0
19.07s [solution] find --under 0.1.0.0.1.1.0.1.0.0.1.0.0 --depth 5 --limit 10 --title Skip --pid 32888 → 0
19.14s [solution] find --role button --title Pause --depth 40 --limit 5 --pid 32888 → 0
19.22s [solution] find --under 0.1.0.0.1.1.0.1.0.0.1.0.0 --depth 5 --limit 10 --title My Ad Center --pid 32888 → 0
19.29s [solution] find --under 0.1.0.0.1.1.0.1.0.0.1.0.0 --depth 5 --limit 10 --title Sponsored --pid 32888 → 0
```
