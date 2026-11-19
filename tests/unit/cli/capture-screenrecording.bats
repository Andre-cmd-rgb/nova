#!/usr/bin/env bats

# nova-capture-screenrecording: what gpu-screen-recorder is asked to record
# (the region or monitor picked, its size, the sound), and the stop that
# finishes the file and says so. Every program it runs is a stub: the
# recorder writes its file and runs until it is sent SIGINT, as the real one
# does, and nova-session-pgrep sees and signals it alone.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home CALLS=$SCRATCH/calls XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$SCRATCH/bin" "$HOME" "$XDG_RUNTIME_DIR"
  export NOVA_SCREENRECORD_DIR=$SCRATCH/videos
  echo '10,20 300x200' >"$SCRATCH/picked"
  echo '[{"focused":true,"width":2560,"height":1440}]' >"$SCRATCH/monitors"
  # In Python: started in the background by a script, a bash stub would have
  # SIGINT ignored, past any trap, where a program can take it back.
  cat >"$SCRATCH/bin/gpu-screen-recorder" <<'STUB'
#!/usr/bin/python3 -I
import os, signal, sys, time
scratch = os.environ["SCRATCH"]
with open(os.environ["CALLS"], "a") as calls:
    calls.write("gsr " + " ".join(sys.argv[1:]) + "\n")
with open(scratch + "/gsr.pid", "w") as pid:
    pid.write(str(os.getpid()))
if os.path.exists(scratch + "/gsr-fails"):
    sys.exit(1)
with open(sys.argv[sys.argv.index("-o") + 1], "w") as video:
    video.write("VIDEO\n")
def stop(*_):
    os.remove(scratch + "/gsr.pid")
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(0.05)
STUB
  chmod +x "$SCRATCH/bin/gpu-screen-recorder"
  # Finds the recorder, as nova-session-pgrep does, and with --signal sends it
  # the signal, saying so.
  stub nova-session-pgrep 'if [[ $1 == --signal ]]; then echo "signal $*" >>"$CALLS"; [[ -s $SCRATCH/gsr.pid ]] || exit 1; kill -s "$2" "$(cat "$SCRATCH/gsr.pid")"; else [[ $* == "-f ^gpu-screen-recorder" && -s $SCRATCH/gsr.pid ]] && kill -0 "$(cat "$SCRATCH/gsr.pid")" 2>/dev/null; fi'
  stub nova-capture-region 'echo "region $*" >>"$CALLS"; [[ -s $SCRATCH/picked ]] || exit 1; cat "$SCRATCH/picked"'
  stub nova-hyprland-monitor-focused 'echo DP-1'
  stub hyprctl 'cat "$SCRATCH/monitors"'
  stub nova-shell 'echo "shell $*" >>"$CALLS"'
  stub nova-notification-send 'echo "notify $*" >>"$CALLS"'
  stub ffprobe 'case $* in *packet=flags*) cat "$SCRATCH/flags" 2>/dev/null ;; *codec_type*) [[ ! -e $SCRATCH/sound ]] || echo audio ;; esac; true'
  stub ffmpeg 'echo "ffmpeg $*" >>"$CALLS"; out=""; for a; do [[ $a == -loglevel ]] && break; out=$a; done; echo DONE >"$out"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() {
  if [[ -s $SCRATCH/gsr.pid ]]; then kill -9 "$(cat "$SCRATCH/gsr.pid")" 2>/dev/null || true; fi
  teardown_scratch
}

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

record() { "$REPO_ROOT/src/cli/bin/nova-capture-screenrecording" "$@"; }

asked() { sed -n 's/^gsr //p' "$CALLS"; }

# The videos go too: one started in the same second would have the same name,
# and be taken for started before the recorder had begun.
stop_it() {
  record --stop-recording >"$SCRATCH/stopped"
  rm -rf "$NOVA_SCREENRECORD_DIR"
}

@test "a region picked is recorded as gpu-screen-recorder takes one, at its own size" {
  record
  [[ $(asked) =~ ^-w\ 300x200\+10\+20\ -k\ auto\ -f\ 60\ -fm\ cfr\ -fallback-cpu-encoding\ yes\ -o\ $SCRATCH/videos/screenrecording-[0-9_-]+\.mp4$ ]]
  grep -qx 'region smart --match-monitor' "$CALLS"
  grep -qx 'shell -q nova.indicators refresh' "$CALLS"
  [ "$(cat "$XDG_RUNTIME_DIR/nova/screenrecord-filename")" = "$(asked | sed 's/.* -o \([^ ]*\).*/\1/')" ]
  stop_it
}

@test "a monitor is recorded as itself, at most at 4K, or at the resolution asked for" {
  echo monitor:HDMI-A-1 >"$SCRATCH/picked"
  record
  [[ $(asked) == '-w HDMI-A-1 -s 0x0 -k auto '* ]]
  stop_it
  : >"$CALLS"
  echo '[{"focused":true,"width":5120,"height":2880}]' >"$SCRATCH/monitors"
  record
  [[ $(asked) == '-w HDMI-A-1 -s 3840x2160 -k auto '* ]]
  stop_it
  : >"$CALLS"
  record --resolution=1920x1080
  [[ $(asked) == '-w HDMI-A-1 -s 1920x1080 -k auto '* ]]
  stop_it
  : >"$CALLS"
  echo '10,20 300x200' >"$SCRATCH/picked"
  record --resolution=1280x720
  [[ $(asked) == '-w 300x200+10+20 -s 1280x720 -k auto '* ]]
  stop_it
}

@test "--fullscreen records the focused monitor, with nothing to pick" {
  record --fullscreen
  [[ $(asked) == '-w DP-1 -s 0x0 -k auto '* ]]
  fails grep -q '^region' "$CALLS"
  stop_it
}

@test "the desktop and the microphone are recorded in one track" {
  record --with-desktop-audio
  [[ $(asked) == *' -a default_output -ac aac' ]]
  stop_it
  : >"$CALLS"
  record --with-desktop-audio --with-microphone-audio
  [[ $(asked) == *' -a default_output|default_input -ac aac' ]]
  stop_it
}

@test "a pick given up records nothing, and is no failure" {
  : >"$SCRATCH/picked"
  run record
  [ "$status" -eq 0 ]
  fails grep -q '^gsr' "$CALLS"
}

@test "a recorder that ends at once leaves nothing to stop" {
  touch "$SCRATCH/gsr-fails"
  record
  [ ! -e "$XDG_RUNTIME_DIR/nova/screenrecord-filename" ]
  fails grep -q '^shell' "$CALLS"
}

@test "the stop finishes the file, its first frame cut, and says it is saved" {
  record
  file=$(asked | sed 's/.* -o \([^ ]*\).*/\1/')
  : >"$CALLS"
  run record --stop-recording
  [ "$status" -eq 0 ]
  [ "$output" = "$file" ]
  grep -qx 'signal --signal INT -f ^gpu-screen-recorder' "$CALLS"
  grep -qx "ffmpeg -y -ss 0.1 -i $file -c:v copy ${file%.mp4}-processed.mp4 -loglevel quiet" "$CALLS"
  [ "$(cat "$file")" = DONE ]
  [ ! -e "${file%.mp4}-processed.mp4" ]
  grep -qx "notify Screen recording saved Show in Files with Super + Alt + , (or click this) -t 10000 --image ${file%.mp4}-preview.png --exec nautilus --select $file" "$CALLS"
  grep -qx 'shell -q nova.indicators refresh' "$CALLS"
  [ ! -e "$XDG_RUNTIME_DIR/nova/screenrecord-filename" ]
}

@test "a recording with warm-up packets is encoded again, and its sound evened out" {
  record --with-desktop-audio
  file=$(asked | sed 's/.* -o \([^ ]*\).*/\1/')
  printf 'K__\nD__\n' >"$SCRATCH/flags"
  touch "$SCRATCH/sound"
  stop_it
  grep -qx "ffmpeg -y -ss 0.1 -i $file -c:v libx264 -preset veryfast -crf 20 -af volume=enable='lt(t,0.4)':volume=0,afade=t=in:st=0.4:d=0.05,loudnorm=I=-14:TP=-1.5:LRA=11 ${file%.mp4}-processed.mp4 -loglevel quiet" "$CALLS"
}

@test "run again while recording, it stops whatever it is given; --stop-recording alone with none fails" {
  record
  record --with-desktop-audio >/dev/null
  [ "$(grep -c '^gsr' "$CALLS")" -eq 1 ]
  grep -q '^signal --signal INT' "$CALLS"
  run record --stop-recording
  [ "$status" -eq 1 ]
}

@test "a recorder that will not stop is killed, and that is said" {
  record
  stub nova-session-pgrep 'if [[ $1 == --signal ]]; then echo "signal $*" >>"$CALLS"; [[ $2 == KILL ]] && kill -9 "$(cat "$SCRATCH/gsr.pid")"; true; else [[ -s $SCRATCH/gsr.pid ]] && kill -0 "$(cat "$SCRATCH/gsr.pid")" 2>/dev/null; fi'
  stub sleep 'true'
  run record --stop-recording
  grep -qx 'signal --signal KILL -f ^gpu-screen-recorder' "$CALLS"
  grep -q '^notify -u critical -t 5000 .*did not stop in time' "$CALLS"
  fails grep -q '^ffmpeg' "$CALLS"
}
