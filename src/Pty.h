/* Pty.h -- the shell on the other end of the terminal. */
#ifndef TERM_PTY_H
#define TERM_PTY_H
#include <sys/types.h>

/* Start the user's login shell on a new pseudo-terminal of rows x cols,
 * or command when it is set: a bare path runs as a login shell, anything
 * with arguments under /bin/sh -c. Returns the master fd (blocking,
 * close-on-exec) and the child's pid through *pid, or -1. */
int  pty_spawn(int rows, int cols, const char *command, pid_t *pid);

/* Tell the kernel (and so the shell's SIGWINCH) the new size. */
void pty_resize(int fd, int rows, int cols, int px_w, int px_h);

/* Write all of buf, retrying a short or interrupted write. */
void pty_write_all(int fd, const char *buf, size_t len);

#endif
