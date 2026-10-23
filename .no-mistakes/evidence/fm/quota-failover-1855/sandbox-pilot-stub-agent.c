/* Fake agent for the quota-failover sandbox pilot. Compiled once per lab and
 * installed under every agent binary name on the lab-only PATH, so the
 * process name (ps comm) is the harness name the liveness probe expects.
 *
 * It draws the composer shape its harness draws - claude 2.x: a solid rule,
 * a prompt-glyph row holding the typed text with the cursor on it, a solid
 * rule; pi: the same pair of rules around a glyphless row - so the control
 * plane can prove the composer empty before it types /exit, and answers each
 * submitted line: with a provider 429 while the lab's mode file says "429",
 * otherwise with "ok". /exit, EOF or a signal ends it. The lab pane is wide
 * enough that typed text never wraps. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#ifndef MODE_FILE
#error MODE_FILE must be defined
#endif

static struct termios saved;
static int raw_on = 0;

static void restore_tty(void) {
  if (raw_on) tcsetattr(STDIN_FILENO, TCSANOW, &saved);
}

static int mode_is_429(void) {
  char buf[16] = {0};
  FILE *f = fopen(MODE_FILE, "r");
  if (!f) return 0;
  size_t n = fread(buf, 1, sizeof buf - 1, f);
  fclose(f);
  buf[n] = 0;
  return strncmp(buf, "429", 3) == 0;
}

static const char *RULE =
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80";
static const char *GLYPH = "\xe2\x9d\xaf\xc2\xa0"; /* claude: U+276F + NBSP; pi: no glyph */

static void draw_composer(const char *buf) {
  printf("%s\n%s%s\n%s\033[1A\r%s%s", RULE, GLYPH, buf, RULE, GLYPH, buf);
  fflush(stdout);
}

static void sig_exit(int s) {
  restore_tty();
  signal(s, SIG_DFL);
  raise(s);
}

int main(int argc, char **argv) {
  const char *name = strrchr(argv[0], '/');
  name = name ? name + 1 : argv[0];
  if (!strcmp(name, "pi")) GLYPH = "";
  for (int i = 1; i < argc; i++)
    if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-v")) {
      printf("%s 0.0.0-qflab-stub\n", name);
      return 0;
    }
  setvbuf(stdout, NULL, _IOFBF, 1 << 16);
  if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &saved) == 0) {
    struct termios t = saved;
    t.c_lflag &= ~(ICANON | ECHO);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
    raw_on = 1;
    atexit(restore_tty);
    signal(SIGINT, sig_exit);
    signal(SIGTERM, sig_exit);
    signal(SIGHUP, sig_exit);
  }
  printf("[qflab stub %s pid=%d up; argv:", name, (int)getpid());
  for (int i = 1; i < argc && i < 8; i++) printf(" %.60s", argv[i]);
  printf("]\n");
  char buf[16384];
  size_t len = 0;
  unsigned turn = 0;
  int esc = 0;
  buf[0] = 0;
  draw_composer(buf);
  int c;
  while ((c = getchar()) != EOF) {
    if (esc) { /* drop an escape sequence up to its final byte */
      if (esc == 1 && c != '[' && c != 'O') esc = 0;
      else if (esc == 1) esc = 2;
      else if ((c >= '@' && c <= '~') && c != '[') esc = 0;
      continue;
    }
    if (c == 0x1b) { esc = 1; continue; }
    if (c == 0x04 && len == 0) break;
    if (c == 0x7f || c == 0x08) {
      if (len) {
        /* drop one UTF-8 character */
        do len--; while (len && (buf[len] & 0xc0) == 0x80);
        buf[len] = 0;
        printf("\r\033[K%s%s", GLYPH, buf);
        fflush(stdout);
      }
      continue;
    }
    if (c == '\r' || c == '\n') {
      printf("\033[1A\r\033[J");
      if (len == 0) { draw_composer(buf); continue; }
      printf("> %s\n", buf);
      if (strstr(buf, "/exit") || !strcmp(buf, "/quit")) {
        printf("[qflab stub %s exiting]\n", name);
        fflush(stdout);
        return 0;
      }
      turn++;
      if (mode_is_429())
        printf("  API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"usage limit reached\"}}\n");
      else
        printf("  ok (turn %u)\n", turn);
      len = 0;
      buf[0] = 0;
      draw_composer(buf);
      continue;
    }
    if (c < 0x20) continue;
    if (len + 1 < sizeof buf) {
      buf[len++] = (char)c;
      buf[len] = 0;
      putchar(c);
      fflush(stdout);
    }
  }
  return 0;
}
