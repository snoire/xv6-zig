#include "kernel/types.h"
#include "kernel/stat.h"
#include "user/user.h"

#define LIMIT 35

int main(int argc, char *argv[])
{
    int p[2], prime, num;
    int writefd, readfd;

    pipe(p);
    for (int i = 2; i <= LIMIT; i++) {
        write(p[1], &i, sizeof(int));
    }

    while (1) {
        close(p[1]);
        readfd = p[0];

        if (read(readfd, &prime, sizeof(int)) == 0)
            exit(0);

        printf("prime %d\n", prime);

        pipe(p);
        if (fork() > 0) {       /* parent */
            close(p[0]);
            writefd = p[1];
            while (read(readfd, &num, sizeof(int))) {
                if (num % prime != 0) {
                    write(writefd, &num, sizeof(int));
                }
            }

            close(writefd);     /* notify the child that the write-side has no data */
            wait((int *) 0);
            exit(0);
        }
    }
}
