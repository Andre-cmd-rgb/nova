// The two programs tools/xwayland-game-check runs in its nested Hyprland, in
// one file that it compiles as it starts.
//
//   xwayland-game-check input W H    a mouse and a keyboard, made on
//                                    $WAYLAND_DISPLAY as a real mouse and
//                                    keyboard are; commands on stdin
//   xwayland-game-check game [window | fullscreen W H]
//                                    an SDL3 game on X11 that takes the
//                                    mouse as Minecraft 26 does; commands on
//                                    stdin
//   xwayland-game-check pixel PPM X Y
//                                    the colour at X, Y of a grim picture
//
// input's commands, each answered "ok" once the compositor has it:
//   move X Y      the pointer to X, Y of the W x H layout
//   rel DX DY     a motion of the mouse, relative, as libinput gives one
//   key CODE      a press and release (evdev code, us keymap)
// The keyboard is there from the start: Hyprland gives no window the keyboard
// without one, and a pointer lock needs the keyboard on its window.
//
// game's commands, each answered once done:
//   size          "size W H": the window's size in X11 pixels
//   grab          as Minecraft's MouseHandler.grabMouse: the cursor to the
//                 middle, then relative mode; motions count by xrel
//   release       as releaseMouse: the cursor to the middle, then relative
//                 mode off (a menu); "game XREL" is what the grab counted
//   switch W H    a new fullscreen mode while fullscreen, as Minecraft's
//                 setting does
//   raw           "raw ABSOLUTE ALL": the X server's raw motions so far, and
//                 how many came from an absolute device (XWayland has one for
//                 motions that come without a relative motion)
//   quit          "menu FROM TO BACK": the menu cursor's x, first and last,
//                 and how often it went left, put back, while the mouse only
//                 went right
// Exclusive fullscreen is as Minecraft's Window class does it: the closest
// mode, fullscreen, and the mouse kept in the window (SDL_SetWindowMouseGrab).
// The window shows its left half red, its right half green and its top tenth
// blue, so that a picture of the screen shows how it was scaled.
#define _GNU_SOURCE
#include <SDL3/SDL.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

// The two input protocols, zwlr_virtual_pointer_v1 and zwp_virtual_keyboard_v1,
// written out here (their requests only) so that nothing is generated.
static const struct wl_interface vptr_iface, vkbd_iface;
static const struct wl_interface *types[] = {
    NULL, NULL, NULL, NULL, NULL, &wl_seat_interface, &vptr_iface, &wl_seat_interface, &vkbd_iface,
};
static const struct wl_message vptr_mgr_requests[] = {
    {"create_virtual_pointer", "?on", types + 5},
    {"destroy", "", types},
};
static const struct wl_interface vptr_mgr_iface = {"zwlr_virtual_pointer_manager_v1", 1, 2, vptr_mgr_requests, 0, NULL};
static const struct wl_message vptr_requests[] = {
    {"motion", "uff", types},      {"motion_absolute", "uuuuu", types}, {"button", "uuu", types},
    {"axis", "uuf", types},        {"frame", "", types},                {"axis_source", "u", types},
    {"axis_stop", "uu", types},    {"axis_discrete", "uufi", types},    {"destroy", "", types},
};
static const struct wl_interface vptr_iface = {"zwlr_virtual_pointer_v1", 1, 9, vptr_requests, 0, NULL};
static const struct wl_message vkbd_mgr_requests[] = {
    {"create_virtual_keyboard", "on", types + 7},
};
static const struct wl_interface vkbd_mgr_iface = {"zwp_virtual_keyboard_manager_v1", 1, 1, vkbd_mgr_requests, 0, NULL};
static const struct wl_message vkbd_requests[] = {
    {"keymap", "uhu", types},
    {"key", "uuu", types},
    {"modifiers", "uuuu", types},
    {"destroy", "", types},
};
static const struct wl_interface vkbd_iface = {"zwp_virtual_keyboard_v1", 1, 4, vkbd_requests, 0, NULL};

static struct wl_proxy *pointer_mgr, *keyboard_mgr;
static struct wl_seat *seat;

static void global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
  if (!strcmp(iface, vptr_mgr_iface.name))
    pointer_mgr = wl_registry_bind(r, name, &vptr_mgr_iface, 1);
  else if (!strcmp(iface, vkbd_mgr_iface.name))
    keyboard_mgr = wl_registry_bind(r, name, &vkbd_mgr_iface, 1);
  else if (!strcmp(iface, wl_seat_interface.name) && !seat)
    seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
}
static void global_remove(void *data, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener listener = {global, global_remove};

static uint32_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

static int input(int argc, char **argv) {
  if (argc < 4) return 2;
  uint32_t w = atoi(argv[2]), h = atoi(argv[3]);
  struct wl_display *dpy = wl_display_connect(NULL);
  if (!dpy) { fprintf(stderr, "input: no Wayland display\n"); return 1; }
  struct wl_registry *reg = wl_display_get_registry(dpy);
  wl_registry_add_listener(reg, &listener, NULL);
  wl_display_roundtrip(dpy);
  if (!pointer_mgr || !keyboard_mgr || !seat) { fprintf(stderr, "input: no virtual pointer or keyboard\n"); return 1; }
  struct wl_proxy *ptr = wl_proxy_marshal_flags(pointer_mgr, 0, &vptr_iface, 1, 0, seat, NULL);
  struct wl_proxy *kb = wl_proxy_marshal_flags(keyboard_mgr, 0, &vkbd_iface, 1, 0, seat, NULL);
  struct xkb_context *ctx = xkb_context_new(0);
  char *text = xkb_keymap_get_as_string(xkb_keymap_new_from_names(ctx, NULL, 0), XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t size = strlen(text) + 1;
  int fd = memfd_create("keymap", 0);
  if (fd < 0 || ftruncate(fd, size) < 0) return 1;
  char *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  memcpy(map, text, size);
  wl_proxy_marshal_flags(kb, 0, NULL, 1, 0, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)size);
  wl_display_roundtrip(dpy);
  setvbuf(stdout, NULL, _IOLBF, 0);
  puts("ok");
  char line[128];
  while (fgets(line, sizeof line, stdin)) {
    double dx, dy;
    int x, y;
    if (sscanf(line, "rel %lf %lf", &dx, &dy) == 2) {
      wl_proxy_marshal_flags(ptr, 0, NULL, 1, 0, now_ms(), wl_fixed_from_double(dx), wl_fixed_from_double(dy));
      wl_proxy_marshal_flags(ptr, 4, NULL, 1, 0);
    } else if (sscanf(line, "move %d %d", &x, &y) == 2) {
      wl_proxy_marshal_flags(ptr, 1, NULL, 1, 0, now_ms(), (uint32_t)x, (uint32_t)y, w, h);
      wl_proxy_marshal_flags(ptr, 4, NULL, 1, 0);
    } else if (sscanf(line, "key %d", &x) == 1) {
      wl_proxy_marshal_flags(kb, 1, NULL, 1, 0, now_ms(), (uint32_t)x, WL_KEYBOARD_KEY_STATE_PRESSED);
      wl_display_roundtrip(dpy);
      usleep(30000);
      wl_proxy_marshal_flags(kb, 1, NULL, 1, 0, now_ms(), (uint32_t)x, WL_KEYBOARD_KEY_STATE_RELEASED);
    }
    wl_display_roundtrip(dpy);
    puts("ok");
  }
  wl_display_disconnect(dpy);
  return 0;
}

typedef void (*gl_uint_fn)(unsigned int);
typedef void (*gl_color_fn)(float, float, float, float);
typedef void (*gl_rect_fn)(int, int, int, int);

// The raw motions, as a game reads them for its relative mouse, on a
// connection of their own. A raw motion from an absolute device carries a
// position, not a motion: a game that takes it for a motion, or that reads
// the core pointer's axes while they are that device's (SDL before 3.4.16
// does once), turns a mouse's motions into jumps.
static Display *raw_display;
static int xi_opcode, raw_all, raw_absolute, known_count;
static int known_ids[64];
static bool known_absolute[64];

static void raw_open(void) {
  int event, error, major = 2, minor = 2;
  raw_display = XOpenDisplay(NULL);
  if (!raw_display || !XQueryExtension(raw_display, "XInputExtension", &xi_opcode, &event, &error) ||
      XIQueryVersion(raw_display, &major, &minor) != Success) {
    fprintf(stderr, "game: no XInput 2 for raw motions\n");
    raw_display = NULL;
    return;
  }
  unsigned char bits[XIMaskLen(XI_LASTEVENT)] = {0};
  XIEventMask mask = {XIAllMasterDevices, sizeof bits, bits};
  XISetMask(bits, XI_RawMotion);
  XISelectEvents(raw_display, DefaultRootWindow(raw_display), &mask, 1);
  XFlush(raw_display);
}

static bool device_absolute(int id) {
  for (int i = 0; i < known_count; i++)
    if (known_ids[i] == id) return known_absolute[i];
  bool absolute = false;
  int n;
  XIDeviceInfo *info = XIQueryDevice(raw_display, id, &n);
  for (int i = 0; info && i < info->num_classes; i++) {
    XIValuatorClassInfo *v = (XIValuatorClassInfo *)info->classes[i];
    if (v->type == XIValuatorClass && v->number == 0) absolute = v->mode == XIModeAbsolute;
  }
  if (info) XIFreeDeviceInfo(info);
  if (known_count < 64) {
    known_ids[known_count] = id;
    known_absolute[known_count++] = absolute;
  }
  return absolute;
}

static void raw_read(void) {
  while (raw_display && XPending(raw_display)) {
    XEvent e;
    XNextEvent(raw_display, &e);
    if (e.type != GenericEvent || e.xcookie.extension != xi_opcode || !XGetEventData(raw_display, &e.xcookie)) continue;
    if (e.xcookie.evtype == XI_RawMotion) {
      const XIRawEvent *raw = e.xcookie.data;
      raw_all++;
      if (device_absolute(raw->sourceid)) {
        raw_absolute++;
        fprintf(stderr, "raw motion from absolute device %d\n", raw->sourceid);
      }
    }
    XFreeEventData(raw_display, &e.xcookie);
  }
}

static bool fullscreen_mode(SDL_Window *w, int mw, int mh) {
  SDL_DisplayMode mode;
  if (!SDL_GetClosestFullscreenDisplayMode(SDL_GetDisplayForWindow(w), mw, mh, 0, true, &mode)) return false;
  return SDL_SetWindowFullscreenMode(w, &mode);
}

static int game(int argc, char **argv) {
  if (!getenv("SDL_VIDEO_DRIVER")) SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "x11");
  if (!SDL_Init(SDL_INIT_VIDEO)) { fprintf(stderr, "game: %s\n", SDL_GetError()); return 1; }
  setvbuf(stdout, NULL, _IOLBF, 0);
  raw_open();
  SDL_Window *w = SDL_CreateWindow("xwayland-game-check", 854, 480, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE);
  if (!w || !SDL_GL_CreateContext(w)) { fprintf(stderr, "game: %s\n", SDL_GetError()); return 1; }
  gl_uint_fn glClear = (gl_uint_fn)SDL_GL_GetProcAddress("glClear");
  gl_uint_fn glEnable = (gl_uint_fn)SDL_GL_GetProcAddress("glEnable");
  gl_color_fn glClearColor = (gl_color_fn)SDL_GL_GetProcAddress("glClearColor");
  gl_rect_fn glScissor = (gl_rect_fn)SDL_GL_GetProcAddress("glScissor");
  SDL_GL_SetSwapInterval(1);
  if (argc >= 5 && !strcmp(argv[2], "fullscreen")) {
    if (!fullscreen_mode(w, atoi(argv[3]), atoi(argv[4]))) fprintf(stderr, "game: no mode: %s\n", SDL_GetError());
    SDL_SetWindowFullscreen(w, true);
    SDL_SyncWindow(w);
    SDL_SetWindowMouseGrab(w, true);
  }
  int phase = 0;
  double xrel = 0, first = -1, last = -1, back = 0;
  char line[128];
  size_t got = 0;
  for (;;) {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
      if (e.type == SDL_EVENT_QUIT) return 0;
      if (e.type != SDL_EVENT_MOUSE_MOTION) continue;
      // Every motion goes to the log, for a check that fails.
      fprintf(stderr, "motion %d at %.1f %.1f by %.1f %.1f\n", phase, e.motion.x, e.motion.y, e.motion.xrel, e.motion.yrel);
      if (phase == 1) xrel += e.motion.xrel;
      if (phase == 2) {
        if (first < 0) first = e.motion.x;
        if (last >= 0 && e.motion.x < last - 0.5) back++;
        last = e.motion.x;
      }
    }
    raw_read();
    struct pollfd p = {.fd = 0, .events = POLLIN};
    while (poll(&p, 1, 0) > 0 && (p.revents & (POLLIN | POLLHUP))) {
      char c;
      if (read(0, &c, 1) != 1) return 0;
      if (c != '\n') {
        if (got < sizeof line - 1) line[got++] = c;
        continue;
      }
      line[got] = 0;
      got = 0;
      int ww, wh, mw, mh;
      SDL_GetWindowSizeInPixels(w, &ww, &wh);
      if (!strcmp(line, "size")) {
        printf("size %d %d\n", ww, wh);
      } else if (!strcmp(line, "grab")) {
        SDL_WarpMouseInWindow(w, ww / 2.0f, wh / 2.0f);
        SDL_SetWindowRelativeMouseMode(w, true);
        phase = 1;
        puts("grabbed");
      } else if (!strcmp(line, "release")) {
        SDL_WarpMouseInWindow(w, ww / 2.0f, wh / 2.0f);
        SDL_SetWindowRelativeMouseMode(w, false);
        phase = 2;
        printf("game %.1f\n", xrel);
      } else if (sscanf(line, "switch %d %d", &mw, &mh) == 2) {
        fullscreen_mode(w, mw, mh);
        SDL_SyncWindow(w);
        puts("switched");
      } else if (!strcmp(line, "raw")) {
        raw_read();
        printf("raw %d %d\n", raw_absolute, raw_all);
      } else if (!strcmp(line, "quit")) {
        printf("menu %.1f %.1f %.0f\n", first, last, back);
        SDL_Quit();
        return 0;
      }
    }
    int pw, ph;
    SDL_GetWindowSizeInPixels(w, &pw, &ph);
    glEnable(0x0C11 /* GL_SCISSOR_TEST */);
    glScissor(0, 0, pw / 2, ph);
    glClearColor(1, 0, 0, 1);
    glClear(0x4000 /* GL_COLOR_BUFFER_BIT */);
    glScissor(pw / 2, 0, pw - pw / 2, ph);
    glClearColor(0, 1, 0, 1);
    glClear(0x4000);
    glScissor(0, ph - ph / 10, pw, ph / 10);
    glClearColor(0, 0, 1, 1);
    glClear(0x4000);
    SDL_GL_SwapWindow(w);
  }
}

static int pixel(int argc, char **argv) {
  if (argc < 5) return 2;
  FILE *f = fopen(argv[2], "rb");
  int w, h, max;
  if (!f || fscanf(f, "P6 %d %d %d", &w, &h, &max) != 3) { fprintf(stderr, "pixel: not a PPM\n"); return 1; }
  fgetc(f);
  long x = atol(argv[3]), y = atol(argv[4]);
  if (x < 0 || y < 0 || x >= w || y >= h) return 1;
  fseek(f, (y * w + x) * 3, SEEK_CUR);
  int r = fgetc(f), g = fgetc(f), b = fgetc(f);
  printf("%d %d %d %d %d\n", r, g, b, w, h);
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "input")) return input(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "game")) return game(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "pixel")) return pixel(argc, argv);
  fprintf(stderr, "usage: xwayland-game-check input W H | game [window | fullscreen W H] | pixel PPM X Y\n");
  return 2;
}
