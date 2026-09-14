#include <unistd.h>
#include <stdio.h>
extern int thunderbird_imap_probe(const char *, const char *);
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(20);
    return thunderbird_imap_probe(argv[1], argv[2]);
}
