"""Combine pinned D2H retirement hierarchy and ordered fetch derivatives."""
import argparse
import hashlib
import json
from pathlib import Path

PARENT_MANIFEST = 'eb2f76bf86f087fbad3aaad75f66111ecaacf394cb3e7315b7083d66b18a4e84'
FETCH = {
    'altpcieav_dma_rd_fetch_return_v5.sv':
        '1eb5f38303c9f36989d0c04f4b37d45b440d17459f97967823ab7789ed1e18a7',
    'dma_fetch_commit_return_v5.sv':
        '063574d2e32b6de9c2e7ed4836187b8082245491833a3d08677c92ce06113344',
}


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def checked(path, pin):
    raw = path.read_bytes()
    if digest(raw) != pin:
        raise ValueError('source identity differs: ' + str(path))
    return raw


def compose(parent, fetch, output):
    parent, fetch, output = (Path(p).resolve() for p in (parent, fetch, output))
    if output.exists() or any((p / '.git').exists() for p in (output, *output.parents)):
        raise ValueError('fresh output outside Git required')
    if any(output == p or p in output.parents or output in p.parents for p in (parent, fetch)):
        raise ValueError('output must be separate from both input trees')
    manifest = json.loads(checked(parent / 'd2h-integration.json', PARENT_MANIFEST))
    data = {}
    for name, pin in manifest['outputs'].items():
        if Path(name).name != name or name in ('.', '..'):
            raise ValueError('nonlocal input filename')
        data[name] = checked(parent / name, pin)
    for name, pin in FETCH.items():
        if name not in data:
            raise ValueError('missing original hierarchy member: ' + name)
        data[name] = checked(fetch / name, pin)
    output.mkdir(parents=True, exist_ok=False)
    for name, raw in data.items():
        (output / name).write_bytes(raw)
    report = {'parent_manifest_sha256': PARENT_MANIFEST, 'fetch_inputs': FETCH,
              'outputs': {n: digest(raw) for n, raw in data.items()},
              'replaced_files': list(FETCH), 'elaboration_accepted': False,
              'simulation_accepted': False, 'physical_acceptance': False,
              'production_driver_contract_valid': False}
    (output / 'ordered-duplex-integration.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--fetch', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    compose(args.parent, args.fetch, args.out)
