import unittest
from check_metrics import validate_metrics


def line(cycle, phase, seq, c, r, w, b, s, resp, active):
    return (f'PLATFORM_DDR_METRICS cycle={cycle} phase={phase} seq={seq} '
            f'cycles={c} reads={r} writes={w} bytes={b} stalls={s} '
            f'responses={resp} active={active}')


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.text = '\n'.join([
            line(0, 0, 1, 20, 0, 2, 128, 1, 0, 3),
            line(0, 1, 2, 40, 4, 5, 160, 2, 4, 11),
            line(1, 0, 3, 50, 4, 5, 160, 2, 4, 11),
            line(1, 1, 4, 70, 8, 8, 192, 3, 8, 19),
            'INITIALIZED_BACKEND_PASS scrub=2 reads=8 writes=6'])

    def test_valid(self):
        errors, intervals = validate_metrics(self.text)
        self.assertFalse(errors)
        self.assertEqual([i['enabled_write_bytes'] for i in intervals], [32, 32])

    def test_corruption(self):
        for old, new in [('seq=4', 'seq=3'), ('active=19', 'active=20'),
                         ('bytes=192', 'bytes=1000'), ('bytes=192', 'bytes=159'),
                         ('cycles=70', 'cycles=49'), ('responses=8', 'responses=9'),
                         ('scrub=2', 'scrub=3'), ('reads=8 writes=6', 'reads=9 writes=6'),
                         ('cycles=70', f'cycles={2**64}'),
                         ('phase=1 seq=4', 'phase=1 seq=x')]:
            with self.subTest(old=old, new=new):
                self.assertTrue(validate_metrics(self.text.replace(old, new))[0])

    def test_missing_duplicate(self):
        self.assertTrue(validate_metrics(self.text.split('\n', 1)[1])[0])
        self.assertTrue(validate_metrics(self.text+'\n'+self.text.splitlines()[0])[0])
        self.assertTrue(validate_metrics('\n'.join(self.text.splitlines()[:-1]))[0])


if __name__ == '__main__':
    unittest.main()
