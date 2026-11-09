/*
 * appctl.c -- command-line client for the appshim socket.
 *
 * Usage:
 *   appctl [-s SOCK] COMMAND [ARGS...]   send one command, print the reply line
 *   appctl [-s SOCK] -f                  read commands from stdin, print replies
 *   appctl [-s SOCK] watch               stream events until interrupted
 *
 * SOCK defaults to $APPSHIM_SOCK, else the single /tmp/appshim-*.sock if exactly
 * one exists. Arguments containing spaces are re-quoted so the shim sees them
 * as one token.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <glob.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

static int connect_sock(const char *path) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) { close(s); return -1; }
    return s;
}

/* pick a default socket path: exactly one /tmp/appshim-*.sock, or NULL */
static char *autodetect(void) {
    glob_t g;
    if (glob("/tmp/appshim-*.sock", 0, NULL, &g) != 0) return NULL;
    char *r = NULL;
    if (g.gl_pathc == 1) r = strdup(g.gl_pathv[0]);
    else if (g.gl_pathc > 1) {
        fprintf(stderr, "appctl: multiple sockets found, pass -s SOCK:\n");
        for (size_t i = 0; i < g.gl_pathc; i++) fprintf(stderr, "  %s\n", g.gl_pathv[i]);
    }
    globfree(&g);
    return r;
}

/* append arg to buf, quoting if it has spaces or quotes */
static void append_arg(char *buf, size_t cap, const char *arg) {
    size_t len = strlen(buf);
    int needq = (*arg == 0) || strpbrk(arg, " \t\"") != NULL;
    if (len && len < cap - 1) buf[len++] = ' ';
    if (needq && len < cap - 1) buf[len++] = '"';
    for (const char *p = arg; *p && len < cap - 2; p++) {
        if (*p == '"' || *p == '\\') buf[len++] = '\\';
        buf[len++] = *p;
    }
    if (needq && len < cap - 1) buf[len++] = '"';
    buf[len] = 0;
}

static void drain(int s) {           /* copy socket -> stdout until closed */
    char buf[4096];
    ssize_t n;
    while ((n = read(s, buf, sizeof buf)) > 0) {
        if (write(1, buf, n) < 0) break;
    }
}

int main(int argc, char **argv) {
    const char *sock = getenv("APPSHIM_SOCK");
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "-s") && i + 1 < argc) { sock = argv[++i]; continue; }
        break;
    }
    char *autodet = NULL;
    if (!sock || !*sock) sock = autodet = autodetect();
    if (!sock) {
        fprintf(stderr, "appctl: no socket (set $APPSHIM_SOCK or pass -s SOCK)\n");
        return 2;
    }
    int s = connect_sock(sock);
    if (s < 0) { fprintf(stderr, "appctl: connect %s: %s\n", sock, strerror(errno)); return 2; }
    free(autodet);

    /* stdin pipe mode */
    if (i < argc && !strcmp(argv[i], "-f")) {
        char line[8192];
        while (fgets(line, sizeof line, stdin)) {
            if (write(s, line, strlen(line)) < 0) break;
            char resp[65536];
            ssize_t n = read(s, resp, sizeof resp - 1);
            if (n <= 0) break;
            resp[n] = 0;
            fputs(resp, stdout);
            fflush(stdout);
        }
        close(s);
        return 0;
    }

    if (i >= argc) { fprintf(stderr, "appctl: no command given\n"); close(s); return 2; }

    /* build one command line from the remaining args */
    char cmd[8192] = {0};
    int is_watch = !strcmp(argv[i], "watch");
    for (; i < argc; i++) append_arg(cmd, sizeof cmd, argv[i]);
    strncat(cmd, "\n", sizeof(cmd) - strlen(cmd) - 1);

    if (write(s, cmd, strlen(cmd)) < 0) { perror("write"); close(s); return 2; }

    if (is_watch) {                  /* stream forever */
        drain(s);
    } else {                         /* read exactly one reply line */
        char resp[65536];
        size_t have = 0;
        while (have < sizeof(resp) - 1) {
            ssize_t n = read(s, resp + have, sizeof(resp) - 1 - have);
            if (n <= 0) break;
            have += n;
            if (memchr(resp, '\n', have)) break;
        }
        resp[have] = 0;
        fputs(resp, stdout);
    }
    close(s);
    return 0;
}
