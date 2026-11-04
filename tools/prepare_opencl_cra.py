"""Emit isolated, exact-source OpenCL completion-counter corrections."""
import argparse
import hashlib
import json
from pathlib import Path
import cra_read_clear_safe as repair
from check_cra_sources import check as check_cra_sources

PINS = {
    'stream_copy512': ('a11d7be4c514e2d7152f09d00d31ff795c1f9a55fada7a0f7f225f01f36430ce', 106,
                       '69a0e196e0137b7c83232178cde4d0a40e294c6f87bfcff8b452e4ab6ebb6407'),
    'stream_triad512': ('73f76b1b45667d9e8402bdcbaef73c2bfad3610ae3e69c1a529c781c953e0318', 112,
                        'b68329a2df74165713acb080692e2bfcbceed411242bfe8b88283a04698183ea'),
}

def transform(name, raw):
    original_hash, node, corrected_hash = PINS[name]
    if hashlib.sha256(raw).hexdigest() != original_hash:
        raise ValueError('unsupported original CRA source: ' + name)
    original = raw.decode('utf-8')
    anchor = f'    // clear_on_read_mux(MUX,{node})\n'
    for needle in repair.REQUIRED + (repair.DECL_ANCHOR, anchor, repair.OLD_CLEAR, repair.OLD_READ):
        repair.exactly_once(original, needle)
    edits = [(repair.DECL_ANCHOR, repair.DECL_ANCHOR + repair.NEW_DECLS),
             (anchor, repair.NEW_LOGIC + anchor),
             (repair.OLD_CLEAR, repair.NEW_CLEAR), (repair.OLD_READ, repair.NEW_READ)]
    text = original
    for old, new in edits:
        text = text.replace(old, new, 1)
    inverse = text
    for old, new in reversed(edits):
        repair.exactly_once(inverse, new)
        inverse = inverse.replace(new, old, 1)
    if inverse != original or hashlib.sha256(text.encode()).hexdigest() != corrected_hash:
        raise ValueError('correction differs from validated source')
    return text.encode()

def prepare(source, output):
    source, output = Path(source), Path(output)
    # Validate every input before creating output; never overwrite a source/run.
    candidates = {}
    for name in PINS:
        rel = Path('kernel_hdl') / name / (name + '_function_cra_agent.sv')
        candidates[rel] = transform(name, (source / rel).read_bytes())
    output.mkdir(parents=True, exist_ok=False)
    for rel, data in candidates.items():
        target = output / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    check_cra_sources(output / rel for rel in candidates)
    result = {'profile': 'delayed_snapshot_v1', 'physical_acceptance': False,
              'files': {str(p): hashlib.sha256(b).hexdigest() for p, b in candidates.items()}}
    (output / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output), indent=2))
