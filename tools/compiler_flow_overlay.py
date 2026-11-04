"""Generate an isolated source-pinned flow/status overlay; never install it."""
import argparse
import hashlib
import json
from pathlib import Path

PINS = {
    'Env.pm': ('11cbbdab6774c024f55132e0b0748b42e9c48ab05afe8bdeb3fe486b75236738',
               'daa4ac3c042580201d2a0c1d2546f3442a96222885ed2ef824327491bb48fae7'),
    'AOCOpenCLStage.pm': ('d78c3626f830616f6391e4d0380468ab085aa2a2e698838a4b254c2f7cc80b74',
                        'afb4e623883484a088384d5edf1833f4f63419c494aaa8fe057e7d7b4c9c7224'),
}
STATUS = '''  my $native_status = $?;
  if ($native_status != 0) {
    die "Error: board specification query failed: wait_status=$native_status\\n";
  }
'''
FLOW = '''  # IPA does not pass through the BSP default-flow initialization in aoc.pl.
  # Resolve the model's own flow before constructing flow-qualified queries.
  if ($is_ipa && (!defined($bsp_flow_name) || $bsp_flow_name eq q{})) {
    $bsp_flow_name = acl::Env::aocl_boardspec($board_spec_xml, "defaultname");
    if (!defined($bsp_flow_name) || $bsp_flow_name !~ /\\A[A-Za-z0-9_.-]+\\z/) {
      acl::Common::mydie("IPA model did not supply a valid default compile flow");
    }
  }
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def generate(source, output):
    source, output = Path(source).resolve(), Path(output).absolute()
    resolved = output.resolve()
    if output.exists() or output.is_symlink() or resolved == source or source in resolved.parents or resolved in source.parents:
        raise ValueError('fresh output outside the input tree required')
    candidates = {}
    for name, (before, after) in PINS.items():
        path = source/name
        if path.is_symlink():
            raise ValueError('input symlink refused: '+name)
        raw = path.read_bytes()
        if digest(raw) != before:
            raise ValueError('input source identity mismatch: '+name)
        text = raw.decode()
        if name == 'Env.pm':
            start = text.index('sub aocl_boardspec(@)')
            end = text.index('\n}\n', start)+3
            body = text[start:end]
            anchor = '  if( $result =~ /error/ ) {'
            if body.count(anchor) != 1:
                raise ValueError('ambiguous status insertion')
            text = text[:start]+body.replace(anchor,STATUS+anchor)+text[end:]
        else:
            anchor = '  my $llvm_board_option = acl::AOCDriverCommon::get_llvm_board_option($board_spec_xml);'
            if text.count(anchor) != 1:
                raise ValueError('ambiguous flow insertion')
            text = text.replace(anchor,FLOW+anchor)
        data = text.encode()
        if digest(data) != after:
            raise ValueError('output differs from qualified candidate: '+name)
        candidates[name] = data
    # No output directory is created until both complete candidate hashes pass.
    output.mkdir(parents=True,exist_ok=False)
    for name,data in candidates.items():
        with (output/name).open('xb') as f:
            f.write(data)
    manifest = {'files':{name:dict(original_sha256=pins[0],candidate_sha256=pins[1])
                        for name,pins in PINS.items()},'deployed':False,
                'purpose':'Isolated compiler qualification overlay; never replace shared installation'}
    (output/'overlay-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path,help='directory containing the two original modules')
    parser.add_argument('output',type=Path,help='new isolated output directory')
    args=parser.parse_args()
    generate(args.source,args.output)
