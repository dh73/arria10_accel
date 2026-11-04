import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('metrics', Path(__file__).resolve().parents[2] / 'tools/compare_streaming_metrics.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class Comparison(unittest.TestCase):
    def test_rejects_mismatched_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture = root / 'fixture.sv'
            fixture.write_text('fixed behavioral memory')
            jobs = [root / 'baseline', root / 'candidate']
            for j, cycles in zip(jobs, [200, 100]):
                j.mkdir()
                (j / 'result.json').write_text(json.dumps(dict(state='passed', sources_unchanged=True, suite_exits=[0, 0])))
                (j / 'commands.json').write_text(json.dumps([[['compiler', '-sverilog'], None], [['runner', '+COUNT=16'], 'PASS workload']]))
                (j / 'sources.json').write_text(json.dumps({str(fixture): M.hashlib.sha256(fixture.read_bytes()).hexdigest()}))
                (j / 'suite-0.log').write_text('compiled\n')
                (j / 'suite-1.log').write_text('PASS workload\n' + ''.join(f'STREAM_METRIC base={b} count=16 reads=2 writes=1 full_writes=1 write_bytes=64 cycles={cycles}\n' for b in [0, 256]))
            self.assertEqual(M.compare(*jobs, [fixture])['comparisons'][0]['cycle_speedup'], 2)
            log = jobs[1] / 'suite-1.log'
            saved = log.read_text()
            for bad in [saved.replace('write_bytes=64', 'write_bytes=60'), saved + 'Error! model failure\n', saved + 'PASS workload\n']:
                log.write_text(bad)
                with self.assertRaises(ValueError): M.compare(*jobs, [fixture])
            log.write_text(saved)
            fixture.write_text('changed latency')
            with self.assertRaisesRegex(ValueError, 'fixture bytes changed'):
                M.compare(*jobs, [fixture])


if __name__ == '__main__':
    unittest.main()
