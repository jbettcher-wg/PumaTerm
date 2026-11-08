/*
 * Pty.c -- spawn the shell on a pseudo-terminal.
 *
 * forkpty(3) is in <util.h> on Mac OS X 10.5 (libutil is part of libSystem,
 * -lutil is accepted and harmless). The child gets TERM=xterm-256color and
 * COLORTERM=truecolor because the renderer does both, and a UTF-8 LANG when
 * none is set, since a GUI-launched app on 10.5 inherits no locale at all
 * and btop and friends then fall back to ASCII.
 */
#include "Pty.h"

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int pty_spawn(int rows, int cols, const char *command, pid_t *pid)
{
	struct winsize ws;
	int master = -1;
	pid_t p;

	memset(&ws, 0, sizeof ws);
	ws.ws_row = (unsigned short)rows;
	ws.ws_col = (unsigned short)cols;

	p = forkpty(&master, NULL, NULL, &ws);
	if (p < 0)
		return -1;

	if (p == 0) {
		const char *shell = getenv("SHELL");
		const char *base;
		struct passwd *pw = getpwuid(getuid());
		char argv0[256];

		/* A command with arguments runs under /bin/sh; a bare path is
		 * started as a login shell in its own right, so choosing
		 * /opt/local/bin/zsh behaves like a changed login shell. */
		if (command && *command && strchr(command, ' ')) {
			if (pw && pw->pw_dir)
				chdir(pw->pw_dir);
			setenv("TERM", "xterm-256color", 1);
			setenv("COLORTERM", "truecolor", 1);
			setenv("TERM_PROGRAM", "PumaTerm", 1);
			if (getenv("LANG") == NULL && getenv("LC_ALL") == NULL)
				setenv("LANG", "en_US.UTF-8", 1);
			signal(SIGINT, SIG_DFL);
			signal(SIGQUIT, SIG_DFL);
			signal(SIGCHLD, SIG_DFL);
			execl("/bin/sh", "sh", "-c", command, (char *)NULL);
			_exit(127);
		}
		if (command && *command)
			shell = command;
		if ((shell == NULL || *shell == '\0') && pw && pw->pw_shell && *pw->pw_shell)
			shell = pw->pw_shell;
		if (shell == NULL || *shell == '\0')
			shell = "/bin/bash";
		if (pw && pw->pw_dir)
			chdir(pw->pw_dir);

		setenv("TERM", "xterm-256color", 1);
		setenv("COLORTERM", "truecolor", 1);
		setenv("TERM_PROGRAM", "PumaTerm", 1);
		if (getenv("LANG") == NULL && getenv("LC_ALL") == NULL)
			setenv("LANG", "en_US.UTF-8", 1);

		/* A leading '-' in argv[0] makes it a login shell, so /etc/profile
		 * (and with it MacPorts' PATH) is read, as Terminal.app does. */
		base = strrchr(shell, '/');
		base = base ? base + 1 : shell;
		argv0[0] = '-';
		strncpy(argv0 + 1, base, sizeof argv0 - 2);
		argv0[sizeof argv0 - 1] = '\0';

		signal(SIGINT, SIG_DFL);
		signal(SIGQUIT, SIG_DFL);
		signal(SIGCHLD, SIG_DFL);
		execl(shell, argv0, (char *)NULL);
		_exit(127);
	}

	/* Blocking, deliberately: NSFileHandle's background read reports an
	 * EAGAIN on a non-blocking fd as a zero-length read, which is how EOF
	 * looks, and the first version closed its window at once (measured on
	 * board 1, 2026-11-08). The read runs on its own thread anyway. */
	fcntl(master, F_SETFD, FD_CLOEXEC);
	*pid = p;
	return master;
}

void pty_resize(int fd, int rows, int cols, int px_w, int px_h)
{
	struct winsize ws;

	memset(&ws, 0, sizeof ws);
	ws.ws_row = (unsigned short)rows;
	ws.ws_col = (unsigned short)cols;
	ws.ws_xpixel = (unsigned short)px_w;
	ws.ws_ypixel = (unsigned short)px_h;
	ioctl(fd, TIOCSWINSZ, &ws);
}

void pty_write_all(int fd, const char *buf, size_t len)
{
	while (len > 0) {
		ssize_t n = write(fd, buf, len);

		if (n > 0) {
			buf += n;
			len -= (size_t)n;
		} else if (n < 0 && (errno == EAGAIN || errno == EINTR)) {
			usleep(1000);
		} else {
			return;		/* the shell is gone */
		}
	}
}
