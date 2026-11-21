#!/usr/bin/env bats

# nova-doctor-memory: what "memory in use" (MemTotal less MemAvailable) is
# made of. The kernel's own arithmetic, redone from /proc/meminfo and
# /proc/zoneinfo: what programs and the kernel hold, the free pages on the
# per-CPU lists, and the margins nothing holds (the reserve under the high
# watermarks, and the cache counted as needed). The lines sum to the figure.
# Read from a /proc of the test's own, with the ThinkPad P1's zones.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PROC=$SCRATCH/proc
  mkdir -p "$NOVA_PROC" "$SCRATCH/bin"
  # The graphics memory is another tool's; none here.
  printf '#!/bin/sh\necho "0 0 0"\n' >"$SCRATCH/bin/nova-doctor-gpu-memory"
  cp "$REPO_ROOT/src/cli/bin/nova-doctor-memory" "$SCRATCH/bin/"
  chmod +x "$SCRATCH/bin/"*
}

teardown() { teardown_scratch; }

# Three zones as a 32 GB computer has them: pages. low, high and what each
# keeps from the zones above are the arguments, so one fixture serves both
# watermark settings.
zones() { # dma: low high; dma32: low high; normal: low high; per-cpu count
  cat >"$NOVA_PROC/zoneinfo" <<ZONES
Node 0, zone      DMA
  pages free     3840
        min      7
        low      $1
        high     $2
        spanned  4095
        present  3998
        managed  3841
        protection: (0, 1887, 31778, 31778, 31778)
  pagesets
    cpu: 0
              count:    0
              high:     0
              batch:    1
Node 0, zone    DMA32
  pages free     480000
        min      1002
        low      $3
        high     $4
        spanned  1044480
        present  512881
        managed  483101
        protection: (0, 0, 29890, 29890, 29890)
  pagesets
    cpu: 0
              count:    100
              high:     400
              batch:    63
Node 0, zone   Normal
  pages free     6000000
        min      15885
        low      $5
        high     $6
        spanned  7796736
        present  7796735
        managed  7652002
        protection: (0, 0, 0, 0, 0)
  pagesets
    cpu: 0
              count:    $7
              high:     14090
              batch:    63
    cpu: 1
              count:    $7
              high:     14090
              batch:    63
Node 0, zone  Movable
  pages free     0
        min      32
        low      32
        high     32
        spanned  0
        present  0
        managed  0
        protection: (0, 0, 0, 0, 0)
ZONES
}

# A desktop at rest. MemAvailable is the kernel's own formula on these numbers
# and the zones given: free - reserve + cache - kept + reclaimable - kept.
meminfo() { # MemAvailable
  cat >"$NOVA_PROC/meminfo" <<MEMINFO
MemTotal:       32555776 kB
MemFree:        28000000 kB
MemAvailable:   $1 kB
Buffers:            4000 kB
Cached:          2700000 kB
SwapCached:            0 kB
Active(anon):     700000 kB
Inactive(anon):        0 kB
Active(file):     400000 kB
Inactive(file):   640000 kB
Unevictable:     1500000 kB
AnonPages:        600000 kB
Shmem:           1650000 kB
KReclaimable:     300000 kB
SReclaimable:     299000 kB
SUnreclaim:       150000 kB
KernelStack:       12000 kB
PageTables:        20000 kB
SecPageTables:      4000 kB
VmallocUsed:      237000 kB
Percpu:            11000 kB
AnonHugePages:    204800 kB
MEMINFO
}

@test "at 1.25% the reserve and the kept cache are 1.5 GiB of what is in use" {
  # low 463 MiB, high 861 MiB in all (the empty Movable zone's 32 pages are in
  # the kernel's sum of the low marks too); the reserve is 3841 + (29890 +
  # 13078) + 207185 pages.
  zones 55 103 7040 13078 111535 207185 50000
  # 28000000 - 1015976 + (1040000 - 474648) + (300000 - 150000)
  meminfo 27699376
  run "$SCRATCH/bin/nova-doctor-memory" --total
  [ "$status" -eq 0 ]
  # in use, held, the three margins (1015976 + 474648 + 150000), the per-CPU lists (100100 pages)
  [ "$output" = "4856400 3215776 1640624 400400" ]
  run "$SCRATCH/bin/nova-doctor-memory"
  [ "$status" -eq 0 ]
  [[ $output == *"Memory in use: 4.63 of 31.05 GiB"* ]]
  [[ $output == *"    992.2  the kernel reserve"* ]]
  [[ $output == *"    463.5  page cache counted as needed (half of 1016, at most the low watermarks)"* ]]
  [[ $output == *"    146.5  reclaimable kernel memory counted as needed"* ]]
  [[ $output == *"    391.0  free pages on the per-CPU lists"* ]]
  [[ $output == *"    585.9  programs: their own memory"* ]]
  [[ $output == *"Watermarks: low 464 MiB, high 861 MiB"* ]]
}

@test "the lines sum to the figure, whatever the kernel holds that has no counter" {
  zones 55 103 7040 13078 111535 207185 50000
  # 128 MiB more in use than the kernel's counters name: a driver's pages.
  meminfo $((27699376 - 131072))
  sed -i 's/^MemFree: .*/MemFree:        27868928 kB/' "$NOVA_PROC/meminfo"
  run "$SCRATCH/bin/nova-doctor-memory"
  [[ $output == *"kernel and drivers, not counted elsewhere"* ]]
  # Every line above the rule, summed, is the line below it.
  sum=$(awk '/^ *-+$/ { exit } $1 ~ /^-?[0-9.]+$/ && NF > 1 { s += $1 } END { printf "%.0f", s }' <<<"$output")
  total=$(awk 'seen && $1 ~ /^[0-9.]+$/ { printf "%.0f", $1; exit } /^ *-+$/ { seen = 1 }' <<<"$output")
  [ -n "$total" ]
  [ "$((sum - total))" -ge -1 ] && [ "$((sum - total))" -le 1 ]
  [ "$total" = "$(((4856400 + 131072 + 512) / 1024))" ]
}

@test "at 100 MiB the same desktop shows 0.9 GiB less in use" {
  # Factor 31: low 168 MiB, high 269 MiB in all; the reserve 3841 + (29890 + 4092) + 64857 pages.
  zones 19 31 2547 4092 40371 64857 10000
  # 28000000 - 410720 + (1040000 - 171876) + (300000 - 150000)
  meminfo 28607404
  run "$SCRATCH/bin/nova-doctor-memory" --total
  [ "$output" = "3948372 3215776 732596 80400" ]
  # 4856400 - 3948372 kB: 887 MiB, and the per-CPU lists' 312 MiB beside.
}

@test "the programs, by their own memory: a share where it can be read, else what is resident" {
  zones 55 103 7040 13078 111535 207185 0
  meminfo 27699376
  mkdir -p "$NOVA_PROC/100" "$NOVA_PROC/200" "$NOVA_PROC/201" "$NOVA_PROC/2"
  echo quickshell >"$NOVA_PROC/100/comm"
  printf 'Rss: 400000 kB\nPss_Anon: 204800 kB\n' >"$NOVA_PROC/100/smaps_rollup"
  printf 'RssAnon:\t  300000 kB\n' >"$NOVA_PROC/100/status"
  # Another user's: no smaps_rollup to read. Two of the same name are one line.
  for pid in 200 201; do
    echo NetworkManager >"$NOVA_PROC/$pid/comm"
    printf 'RssAnon:\t  5120 kB\n' >"$NOVA_PROC/$pid/status"
  done
  # A kernel thread has neither.
  echo kswapd0 >"$NOVA_PROC/2/comm"
  printf 'Name:\tkswapd0\n' >"$NOVA_PROC/2/status"
  run "$SCRATCH/bin/nova-doctor-memory" --programs
  [ "$status" -eq 0 ]
  [[ $output == *"    200.0  quickshell"* ]]
  [[ $output == *"     10.0  NetworkManager (2)"* ]]
  [[ $output != *kswapd0* ]]
}

@test "an argument it does not know is refused" {
  run "$SCRATCH/bin/nova-doctor-memory" --everything
  [ "$status" -eq 2 ]
}
