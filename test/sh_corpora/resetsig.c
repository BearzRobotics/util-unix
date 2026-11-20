/* SPDX-License-Identifier: GPL-2.0-or-later */
/* resetsig.c: run a command with every signal disposition reset to the default and
 * the signal mask empty. The yash sig*-p tests need their runner started this way (the
 * original is yash's own tests/resetsig.c; this is an independent equivalent) so that
 * a dispositions inherited as ignored from the machine that runs the tests cannot
 * change the result. Built by test/test_sh_corpora.sh when a C compiler is available.
 *
 *   resetsig COMMAND [ARGS...]
 */
#define _DEFAULT_SOURCE 1
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    sigset_t none;
    struct sigaction dfl;
    int n;

    if (argc < 2) {
        fprintf(stderr, "resetsig: usage: resetsig COMMAND [ARGS...]\n");
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
    execvp(argv[1], &argv[1]);
    perror("resetsig: exec failed");
    return 126;
}
