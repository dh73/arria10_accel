"""Optional pyslang 12.1.0 static elaboration; never a VCS simulation result."""
import shlex
import sys
import pyslang

print('Supplemental static frontend: pyslang', pyslang.__version__)
driver = pyslang.driver.Driver()
driver.addStandardArgs()
arguments = ['--single-unit', '--timescale', '1ns/1ps',
             '-DPLATFORM_SUPERVISOR_ASSERTIONS', '-DKERNEL_DDR_ASSERTIONS',
             '-DARRIA10_ASSERTIONS', *sys.argv[1:]]
for label, operation in [
    ('command line', lambda: driver.parseCommandLine(shlex.join(arguments))),
    ('options', driver.processOptions),
    ('sources', driver.parseAllSources),
    ('elaboration', driver.runFullCompilation),
]:
    if not operation():
        print('FAILED:', label)
        sys.exit(1)
