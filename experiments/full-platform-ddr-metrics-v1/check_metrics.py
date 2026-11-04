"""Validate two complete DDR measurement intervals, without clock-rate claims."""
import re

PATTERN = re.compile(
    r"PLATFORM_DDR_METRICS cycle=(\d+) phase=(\d+) seq=(\d+) cycles=(\d+) "
    r"reads=(\d+) writes=(\d+) bytes=(\d+) stalls=(\d+) responses=(\d+) active=(\d+)"
)


def validate_metrics(text):
    lines = [s for s in text.splitlines() if s.startswith('PLATFORM_DDR_METRICS')]
    matches = [PATTERN.fullmatch(s) for s in lines]
    if len(matches) != 4 or not all(matches):
        return ['malformed or missing metrics'], []
    rows = [list(map(int, m.groups())) for m in matches]
    if [r[:3] for r in rows] != [[0, 0, 1], [0, 1, 2], [1, 0, 3], [1, 1, 4]]:
        return ['metrics sequence'], []
    failures, intervals = [], []
    previous = None
    for row in rows:
        counts = row[3:]
        cycles, reads, writes, enabled, stalls, responses, active = counts
        if any(x >= 2**64 for x in counts):
            failures.append('counter width')
        if (reads + writes + stalls != active or active > cycles or
                responses > reads or enabled > 64 * writes):
            failures.append('counter conservation')
        if previous and any(a > b for a, b in zip(previous, counts)):
            failures.append('counter regression')
        previous = counts
    # The final scoreboard excludes initialization writes; hardware counters
    # include them. Compare totals only after the test has drained traffic.
    score = re.findall(r'^INITIALIZED_BACKEND_PASS scrub=(\d+) reads=(\d+) writes=(\d+)$', text, re.M)
    if len(score) != 1:
        failures.append('missing backend scoreboard')
    else:
        scrub, reads, writes = map(int, score[0])
        if rows[-1][4:6] != [reads, writes + scrub]:
            failures.append('backend scoreboard mismatch')
    for a, b in (rows[:2], rows[2:]):
        cycles, reads, writes, enabled, stalls, responses, active = [
            y-x for x, y in zip(a[3:], b[3:])]
        if (cycles <= 0 or min(reads, writes, enabled, stalls, responses, active) < 0 or
                reads + writes + stalls != active or active > cycles or
                responses > cycles or enabled > 64 * writes):
            failures.append('invalid interval')
            continue
        intervals.append(dict(cycles=cycles, read_beats=reads, write_beats=writes,
                              enabled_write_bytes=enabled, stall_cycles=stalls,
                              response_beats=responses, active_cycles=active))
    return failures, intervals
