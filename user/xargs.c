#include "kernel/types.h"
#include "kernel/param.h"
#include "user/user.h"

int main(int argc, char *argv[])
{
    char buf[1024];
    char *args[MAXARG];

    for (int i = 0; i < argc - 1; i++)
        args[i] = argv[i + 1];

    while (gets(buf, sizeof(buf))) {
        if (buf[0] == '\0') {
            break;
        }

        args[argc - 1] = buf;
        for (int i = 0, j = argc; buf[i]; i++) {
            if (buf[i] == ' ' || buf[i] == '\n') {
                buf[i] = '\0';
                args[j++] = &buf[i + 1];
            }
        }

        if (fork() > 0) {
            wait((int *) 0);
        } else {
        	exec(args[0], args);
        }
    }

    exit(0);
}
