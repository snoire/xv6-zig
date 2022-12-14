void consputc(int);

int putchar(int c)
{
    consputc(c);
    return 1;
}

int puts(char *s)
{
    int len = 0;
    do {
       consputc(*s++);
       len++;
    } while(*s);

    return len;
}
