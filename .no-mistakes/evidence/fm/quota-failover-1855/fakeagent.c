/* Fake harness agent for the quota-failover lab. Never contacts a provider.
   Prints a composer, records each input line, answers
   "API Error: 429 Too Many Requests" while any argv word contains a line of
   $FAKE_DIR/exhausted, exits on /exit or /quit, and logs argv to
   $FAKE_DIR/launches. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <termios.h>

/* Raw-mode line reader: echoes printable bytes itself, treats Escape as a
   turn cancel that clears the composer (as a real agent TUI does), handles
   backspace, and submits on Enter. */
static int readline_raw(char *buf, size_t cap) {
  size_t n = 0;
  int c;
  for (;;) {
    c = getchar();
    if (c == EOF) return 0;
    if (c == '\r' || c == '\n') { buf[n] = 0; printf("\r\n"); return 1; }
    if (c == 27) { while (n) { printf("\b \b"); n--; } continue; }
    if (c == 127 || c == 8) { if (n) { printf("\b \b"); n--; } continue; }
    if (c == 3) { while (n) { printf("\b \b"); n--; } continue; }
    if (n + 1 < cap) { buf[n++] = (char)c; putchar(c); }
  }
}

static const char *dir(void) {
  const char *d = getenv("FAKE_DIR");
  return d ? d : "/nonexistent";
}

static int exhausted(int argc, char **argv) {
  char p[4096], l[1024];
  int hit = 0;
  snprintf(p, sizeof p, "%s/exhausted", dir());
  FILE *f = fopen(p, "r");
  if (!f) return 0;
  while (fgets(l, sizeof l, f)) {
    l[strcspn(l, "\r\n")] = 0;
    if (!*l) continue;
    for (int i = 1; i < argc; i++)
      if (strstr(argv[i], l)) hit = 1;
  }
  fclose(f);
  return hit;
}

int main(int argc, char **argv) {
  char p[4096];
  static char line[1 << 20];
  snprintf(p, sizeof p, "%s/launches", dir());
  FILE *lg = fopen(p, "a");
  if (lg) {
    fprintf(lg, "%ld pid=%d", (long)time(0), (int)getpid());
    for (int i = 0; i < argc; i++) fprintf(lg, " [%.200s]", argv[i]);
    fprintf(lg, "\n");
    fclose(lg);
  }
  /* Emulate Pi's first-call receipt extension (bin/fm-pi-first-call.sh hook):
     the launch brief's first model call answers ok, or a 429 error while this
     incarnation's pool is listed as exhausted. */
  for (int i = 1; i + 1 < argc; i++) {
    if (strcmp(argv[i], "-e") || !strstr(argv[i + 1], "pi-first-call.ts")) continue;
    static char js[65536];
    FILE *ext = fopen(argv[i + 1], "r");
    if (!ext) continue;
    size_t n = fread(js, 1, sizeof js - 1, ext);
    js[n] = 0;
    fclose(ext);
    char *s = strstr(js, "const path = \"");
    if (!s) continue;
    s += strlen("const path = \"");
    char *e = strchr(s, '"');
    if (!e) continue;
    *e = 0;
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s.tmp", s);
    FILE *r = fopen(tmp, "w");
    if (!r) continue;
    fprintf(r, "%s\n", exhausted(argc, argv) ? "error: 429 Too Many Requests (fake pool exhausted)" : "ok");
    fclose(r);
    rename(tmp, s);
  }
  struct termios t;
  if (tcgetattr(0, &t) == 0) { t.c_lflag &= ~(ICANON | ECHO | ISIG); t.c_iflag &= ~ICRNL; t.c_cc[VMIN] = 1; t.c_cc[VTIME] = 0; tcsetattr(0, TCSANOW, &t); }
  setvbuf(stdout, NULL, _IONBF, 0);
  printf("fake agent %s ready (no provider contacted)\n", argv[0]);
  for (;;) {
    printf("\xe2\x9d\xaf ");
    if (!readline_raw(line, sizeof line)) return 0;
    if (!strcmp(line, "/exit") || !strcmp(line, "/quit")) { if (tcgetattr(0, &t) == 0) { t.c_lflag |= ICANON | ECHO | ISIG; t.c_iflag |= ICRNL; tcsetattr(0, TCSANOW, &t); } return 0; }
    snprintf(p, sizeof p, "%s/inputs", dir());
    FILE *in = fopen(p, "a");
    if (in) {
      fprintf(in, "%d %.300s\n", (int)getpid(), line);
      fclose(in);
    }
    if (exhausted(argc, argv))
      printf("  API Error: 429 Too Many Requests (fake pool exhausted at %ld)\n", (long)time(0));
    else
      printf("  ok: handled input at %ld\n", (long)time(0));
  }
}
