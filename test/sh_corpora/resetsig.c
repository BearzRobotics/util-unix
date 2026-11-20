/* SPDX-License-Identifier: GPL-2.0-or-later */
/* resetsig.c: run a command with every signal disposition reset to the default and
 * the signal mask empty. The yash sig*-p tests need their runner started this way (the
 * original is yash's own tests/resetsig.c; this is an independent equivalent) so that
 * a dispositions inherited as ignored from the machine that runs the tests cannot
 * change the result. Built by test/test_sh_corpora.sh when a C compiler is available.
 *
 *   resetsig [-t SECONDS] COMMAND [ARGS...]
 *
 * -t arms alarm(2) before the exec (a pending alarm survives it), so a hung run ends
 * without a `timeout(1)` in between: timeout installs handlers for INT, QUIT, HUP and
 * TERM, which would undo a signal the test wants to be inherited as ignored.
 */
#define _DEFAULT_SOURCE 1
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    sigset_t none;
    struct sigaction dfl;
    int n;

    unsigned secs = 0;
    int first = 1;

    if (argc > 3 && argv[1][0] == '-' && argv[1][1] == 't' && argv[1][2] == '\0') {
        secs = (unsigned)atoi(argv[2]);
        first = 3;
    }
    if (argc <= first) {
        fprintf(stderr, "resetsig: usage: resetsig [-t SECONDS] COMMAND [ARGS...]\n");
        return 2;
    }
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    dfl.sa_handler = SIG_DFL;
    dfl.sa_flags = 0;
    sigemptyset(&dfl.sa_mask);
    for (n = 1; n < NSIG; n++)
        if (n != SIGKILL && n != SIGSTOP)
            sigaction(n, &dfl, NULL);
    if (secs > 0)
        alarm(secs);
    execvp(argv[first], &argv[first]);
    perror("resetsig: exec failed");
    return 126;
}
