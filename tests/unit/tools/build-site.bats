#!/usr/bin/env bats

# tools/build-site: the site, built from a scratch copy of site/, docs/, src/,
# the palettes and the menu's entries, so that a test can break a doc without
# touching the repository's.

load ../test_helper

setup() {
  if ! command -v cmark-gfm >/dev/null; then
    # CI asks for every test (NOVA_STRICT_TESTS): there a skip would pass
    # the site's checks unseen.
    [[ -z ${NOVA_STRICT_TESTS:-} ]] || { echo "cmark-gfm is missing" >&2; return 1; }
    skip "needs cmark-gfm (CI has it)"
  fi
  setup_scratch
  mkdir -p "$SCRATCH/repo/tools" "$SCRATCH/repo/theme" "$SCRATCH/repo/data/defaults"
  cp -r "$REPO_ROOT/site" "$REPO_ROOT/docs" "$REPO_ROOT/src" "$SCRATCH/repo/"
  cp -r "$REPO_ROOT/theme/palettes" "$SCRATCH/repo/theme/"
  cp "$REPO_ROOT/data/defaults/menu.jsonc" "$SCRATCH/repo/data/defaults/"
  cp "$REPO_ROOT/tools/build-site" "$SCRATCH/repo/tools/"
  REPO=$SCRATCH/repo
  OUT=$SCRATCH/site
}

teardown() { teardown_scratch; }

build() { "$REPO/tools/build-site" --out "$OUT"; }

@test "the user docs become pages, linked to each other, with the maintainer docs on GitHub" {
  run build
  [ "$status" -eq 0 ]
  [ -f "$OUT/index.html" ] && [ -f "$OUT/style.css" ] && [ -f "$OUT/images/desktop.jpg" ]
  [ -f "$OUT/docs/index.html" ] && [ -f "$OUT/docs/install/index.html" ] && [ -f "$OUT/docs/power/index.html" ]
  [ ! -e "$OUT/docs/ARCHITECTURE" ] && [ ! -e "$OUT/docs/releasing" ]
  grep -qF '<h2 id="sending">' "$OUT/docs/airdrop/index.html"
  grep -qF 'href="../airdrop/#sending"' "$OUT/docs/using/index.html"
  grep -qF 'href="install/"' "$OUT/docs/index.html"
  grep -qF 'href="https://github.com/Andre-cmd-rgb/nova/blob/main/docs/ARCHITECTURE.md"' "$OUT/docs/index.html"
  grep -qF 'href="https://github.com/Andre-cmd-rgb/nova/blob/main/src/shell/plugins/bar/README.md"' "$OUT/docs/using/index.html"
  grep -qF 'src="../../images/menu.jpg"' "$OUT/docs/using/index.html"
  [ -f "$OUT/images/menu.jpg" ]
  # The docs' list beside each page, the page itself marked.
  grep -qF '<a href="../install/" aria-current="page">Installing Nova</a>' "$OUT/docs/install/index.html"
  grep -qF '<a href="../patches/">Patches</a>' "$OUT/docs/install/index.html"
  # The landing page's header, its links made to work from a page below it.
  grep -qF '<a href="../../#tour">Tour</a>' "$OUT/docs/install/index.html"
  grep -qF '<a class="brand" href="../../"' "$OUT/docs/install/index.html"
}

@test "headings get GitHub's ids: lowercase, punctuation dropped, a repeat numbered" {
  printf '%s\n' '## Setup' '## Setup' '## What'"'"'s new: v2 (beta) — `nova` & co' '## Écran et réglages' '## Setup' >>"$REPO/docs/patches.md"
  run build
  [ "$status" -eq 0 ]
  grep -qF '<h2 id="setup">' "$OUT/docs/patches/index.html"
  grep -qF '<h2 id="setup-1">' "$OUT/docs/patches/index.html"
  grep -qF '<h2 id="setup-2">' "$OUT/docs/patches/index.html"
  grep -qF '<h2 id="whats-new-v2-beta--nova--co">' "$OUT/docs/patches/index.html"
  grep -qF '<h2 id="écran-et-réglages">' "$OUT/docs/patches/index.html"
}

@test "a link to an #anchor the page does not have fails the build, and leaves the site as it was" {
  build
  sed -i 's/airdrop\.md#sending/airdrop.md#sendin/' "$REPO/docs/using.md"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"docs/using.md: ../airdrop/#sendin: docs/airdrop.md has no heading or id sendin"* ]]
  grep -qF 'href="../airdrop/#sending"' "$OUT/docs/using/index.html"
}

@test "a link to a heading of its own page that is not there fails" {
  sed -i 's/(#night-light)/(#night-lite)/' "$REPO/docs/using.md"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"docs/using.md: #night-lite: docs/using.md has no heading or id night-lite"* ]]
}

@test "a link to a doc or a file the repository does not have fails" {
  sed -i 's/(apps\.md)/(appz.md)/' "$REPO/docs/updates.md"
  sed -i 's,plugins/bar/README\.md,plugins/nothing/README.md,' "$REPO/docs/using.md"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"docs/updates.md links docs/appz.md, which the repository does not have"* ]]
  [[ $output == *"docs/using.md links src/shell/plugins/nothing/README.md, which the repository does not have"* ]]
  [ ! -e "$OUT" ]
}

@test "a picture docs/images does not have fails" {
  sed -i 's,images/menu\.jpg,images/nothing.jpg,' "$REPO/docs/using.md"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"docs/using.md shows images/nothing.jpg, which docs/images does not have"* ]]
}

@test "the landing page's links are checked too" {
  sed -i 's,href="docs/install/",href="docs/instal/",' "$REPO/site/index.html"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"site/index.html: docs/instal/ is no page or picture of the site"* ]]
}

@test "a doc in neither list fails, so a new one is not left out unnoticed" {
  printf '# Something new\n' >"$REPO/docs/new.md"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"docs/new.md is in neither list"* ]]
}

@test "an earlier build is replaced, a folder holding anything else is not" {
  build
  build
  [ -f "$OUT/.nova-site" ]
  rm -rf "$OUT"
  mkdir -p "$OUT"
  touch "$OUT/notes.txt"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"holds files no build made"* ]]
  [ -f "$OUT/notes.txt" ]
  # Not even one that looks like a build, without the mark one leaves.
  rm "$OUT/notes.txt"
  mkdir "$OUT/docs"
  run build
  [ "$status" -eq 1 ]
  [ -d "$OUT/docs" ]
  # Nor a link to a folder, written with a / at its end.
  rm -rf "$OUT"
  mkdir -p "$SCRATCH/elsewhere"
  touch "$SCRATCH/elsewhere/keep"
  ln -s "$SCRATCH/elsewhere" "$OUT"
  run "$REPO/tools/build-site" --out "$OUT/"
  [ "$status" -eq 1 ]
  [ -f "$SCRATCH/elsewhere/keep" ]
}

@test "every palette is a theme of the site, in Settings' order, on every page's picker" {
  run build
  [ "$status" -eq 0 ]
  palettes=$(find "$REPO/theme/palettes" -mindepth 1 -maxdepth 1 -type d | wc -l)
  [ "$(grep -c '^\[data-theme="' "$OUT/themes.css")" -eq $((palettes - 1)) ] # adaptive is :root's
  grep -qF ':root,[data-theme="adaptive"]{color-scheme:dark;--bg:#1a1723;' "$OUT/themes.css"
  grep -qF '@media (prefers-color-scheme: light){:root,[data-theme="adaptive"]{color-scheme:light;' "$OUT/themes.css"
  [ "$(grep -o 'role="radio" aria-checked="false" data-theme="[a-z-]*"' "$OUT/docs/power/index.html" | wc -l)" -eq "$palettes" ]
  order=$(grep -o 'data-theme="[a-z-]*"><span class="swatch"' "$OUT/docs/index.html" | sed 's/data-theme="\([a-z-]*\)".*/\1/' | head -3 | tr '\n' ' ')
  [ "$order" = "adaptive catppuccin catppuccin-latte " ]
  # A new palette is a new theme.
  cp -r "$REPO/theme/palettes/nord" "$REPO/theme/palettes/test-theme"
  run build
  [ "$status" -eq 0 ]
  grep -qF '[data-theme="test-theme"]{' "$OUT/themes.css"
  grep -qF 'data-theme="test-theme"><span class="swatch"' "$OUT/docs/install/index.html"
  grep -qF '>Test Theme</button>' "$OUT/index.html"
}

@test "a faint color is blended until it reads, and a theme whose text cannot read fails" {
  run build
  [ "$status" -eq 0 ]
  # Nord's muted (#616e88) reads at 3:1 on its background: the site's is lighter.
  grep -q '\[data-theme="nord"\]{[^}]*--muted:#[0-9a-f]\{6\};' "$OUT/themes.css"
  ! grep -q '\[data-theme="nord"\]{[^}]*--muted:#616e88;' "$OUT/themes.css"
  sed -i 's/^foreground = .*/foreground = "#3b4252"/' "$REPO/theme/palettes/nord/colors.toml"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"theme nord: the text reads at"* ]]
}

@test "the menu's own code is what the landing page's Super+Space runs, and a function it lacks fails" {
  run build
  [ "$status" -eq 0 ]
  grep -qF 'const NovaMenu = (() => {' "$OUT/menu-model.js"
  grep -q '^function searchRows(' "$OUT/menu-model.js"
  grep -q '^function expression(' "$OUT/menu-model.js"
  grep -qF '\"settings.wifi\": {' "$OUT/menu-model.js" # menu.jsonc, as a string
  sed -i 's/^function searchRows(/function findRows(/' "$REPO/src/shell/plugins/menu/MenuModel.js"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"MenuModel.js has no function searchRows, which the site's Super+Space runs"* ]]
}

@test "a page gets its headings beside it, the pages before and after, and its part of the search" {
  run build
  [ "$status" -eq 0 ]
  grep -qF '<a class="level-2" href="#sending">Sending</a>' "$OUT/docs/airdrop/index.html"
  grep -qF 'rel="prev"><span>Previous</span>The App Center</a>' "$OUT/docs/themes/index.html"
  grep -qF 'rel="next"><span>Next</span>AirDrop</a>' "$OUT/docs/themes/index.html"
  grep -qF '{"u":"docs/airdrop/#sending","p":"AirDrop","h":"Sending",' "$OUT/docs/search-index.json"
  grep -qF '{"u":"docs/install/","p":"Installing Nova","h":"Installing Nova",' "$OUT/docs/search-index.json"
}

@test "a picture gets its size, and one without fails" {
  run build
  [ "$status" -eq 0 ]
  grep -qF 'src="../../images/menu.jpg"' "$OUT/docs/using/index.html"
  grep -q '<img [^>]*src="../../images/menu.jpg"[^>]* width="720" height="450"' "$OUT/docs/using/index.html"
  grep -qF '<img loading="lazy" width="1913" height="1200" src="../../images/themes.jpg"' "$OUT/docs/themes/index.html"
  sed -i 's,<img src="images/desktop.jpg" width="1920" height="1200",<img src="images/desktop.jpg" width="1920",' "$REPO/site/index.html"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *"site/index.html: a picture without its width and height"* ]]
}

@test "a page that would load anything from another site fails" {
  sed -i 's,</head>,<script src="https://cdn.example.com/x.js"></script>\n</head>,' "$REPO/site/index.html"
  printf '%s\n' '.x { background: url(https://example.com/a.png); }' >>"$REPO/site/style.css"
  printf '%s\n' 'fetch("https://example.com/track")' >>"$REPO/site/site.js"
  run build
  [ "$status" -eq 1 ]
  [[ $output == *'site/index.html: loads from another site: <script src="https://cdn.example.com/x.js">'* ]]
  [[ $output == *"style.css: url(https://example.com/a.png) loads from another site"* ]]
  [[ $output == *"site.js: fetches from another site"* ]]
}
