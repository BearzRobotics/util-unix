# 0008: Better diagnostics where the reference tools leave the user stuck

Status: accepted by the maintainer. Date: 2026-11-19. Same rule as util-core
decision 0005 (update 2026-11-19), which has the full text.

Where GNU or util-linux exits non-zero with no message, a bare "write error"
or "memory exhausted", or a message that omits the operand or the reason, we
print a clearer diagnostic on stderr. stdout and the exit status stay the
reference tool's. Failures (out of memory, I/O, invalid input) are reported as
errors with the reference tool's exit status, never as a crash or a silent
exit. Each case is documented in `docs/compatibility/<cmd>.md` (Extensions,
kind "diagnostic") and in the command's man page under "DIFFERENCES FROM GNU",
and has a test that checks stdout and status against the reference and the new
stderr text against the documented one. The wording lives in the wrapper; the
library returns structured errors (decision 0002).
