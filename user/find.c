#include "kernel/types.h"
#include "kernel/stat.h"
#include "kernel/fs.h"
#include "user/user.h"

void find(char *path, const char *file)
{
    char buf[512], *p;
    int fd;
    struct dirent de;
    struct stat st;

    if ((fd = open(path, 0)) < 0) {
        fprintf(2, "find: cannot open %s\n", path);
        return;
    }

    if (fstat(fd, &st) < 0 || st.type != T_DIR) {
        fprintf(2, "find: %s is not directory\n", path);
        close(fd);
        return;
    }

    strcpy(buf, path);
    p = buf + strlen(buf);
    *p++ = '/';
    while (read(fd, &de, sizeof(de)) == sizeof(de)) {
        if (de.inum == 0)
            continue;
        memmove(p, de.name, DIRSIZ);
        p[DIRSIZ] = 0;

        if (stat(buf, &st) < 0) {
            printf("find: cannot stat %s\n", buf);
            continue;
        }

        if (strcmp(de.name, file) == 0)
            printf("%s\n", buf);

        if (st.type == T_DIR && strcmp(de.name, ".") && strcmp(de.name, ".."))
            find(buf, file);
    }
}

int main(int argc, char *argv[])
{
    if (argc < 3) {
        fprintf(2, "Usage: find <path> <file>\n");
        exit(1);
    }

    find(argv[1], argv[2]);
    exit(0);
}
