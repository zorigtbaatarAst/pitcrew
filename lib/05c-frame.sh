#!/usr/bin/env bash
# lib/05b-frame.sh — one frame, in three pieces, and the overflow rules.
#
# NOTE ON THE NAME: every file in this group is `05<letter>-`, never `05-`.
# `lib/*.sh` is sourced in glob order, and a UTF-8 collation IGNORES punctuation
# when comparing — so "05-dashboard.sh" sorts AFTER "05a-cells.sh" on a normal
# desktop and before it under LC_ALL=C. This group has top-level code that reads
# variables the previous file sets, so that difference is the difference between
# working and `PITCREW_REFRESH: unbound variable`. Letters sort the same either
# way.
#
# Split out of one 1200-line file. The seams are the ones that were already
# there in comments: the viewport and the working set, the cell/layout
# arithmetic, the frame builder, and the interactive loop. Bash does not care
# what order functions are defined in, and lib/*.sh is sourced in name order,
# so 05 → 05a → 05b → 05c all load before 06.

# ── one frame, in three pieces ──────────────────────────────────────────────
# Split so the performance test can drive the REAL renderer instead of a
# hand-copied imitation of it. The test used to duplicate the frame body, which
# meant anything added to the dashboard afterwards — a footer, a header — was
# outside the fork budget and could regress unnoticed.
#
#   collect_frame  gathers state (the only part that touches the system)
#   build_frame    turns state into $FRAME (pure; no I/O, no forks)
#   cmd_watch      paints it and handles input

FRAME_N=0
collect_frame() {
  FRAME_N=$(( FRAME_N + 1 ))
  snapshot
  err_scan
  local c
  for c in "${PITCREW_COMPS[@]}"; do
    hist_push "$c" "${SNAP_RSS[$c]:-0}" "${SNAP_CPU[$c]:-0}"
  done
  hist_push_sys "${SYS_CPU_PCT:-0}" "${SYS_MEM_USED_KB:-0}"
  # The verdict is part of a frame's data, not something build_frame works out
  # while drawing. Fork-free like everything else here — see lib/19-diag.sh.
  diag_run
  return 0
}

# Constant for the life of the process; computing it inside the frame would be
# a command substitution, i.e. a fork, on every repaint.
FRAME_TAG="${PITCREW_COLLECTOR}·${PITCREW_REFRESH}s"
[ "${PITCREW_RESTART:-0}" = 1 ] && FRAME_TAG+="·supervised"

build_frame() { # → FRAME, and ROW_COMP for mouse hit-testing
  local W H bw sw frame line ts c app i rule_len r ln avail
  # Part of the frame, not of the caller: build_frame has to be self-contained
  # or the performance test drives something the dashboard does not.
  build_view
  local nview=${#VIEW[@]}
  [ "$nview" -gt 0 ] && [ "$SEL" -ge "$nview" ] && SEL=$((nview - 1))
  [ "$SEL" -lt 0 ] && SEL=0
  # The graph gets whatever the terminal has left over after the fixed
  # columns, so a wide window buys more history instead of dead space.
  term_size; W=$TERM_W; H=$TERM_H
    layout_for_width "$W"
    bw=$GRAPH_W
    local narrow=0; [ "$LAYOUT" = wide ] || narrow=1
    # A short window has to spend its rows on services, not on chrome. The two
    # system gauges fold onto one line and the blank spacers and the legend go
    # — otherwise the header alone eats the screen and the table renders zero
    # rows, which is what a 14-line terminal used to show.
    local compact=0 micro=0
    [ "$H" -lt "${PITCREW_COMPACT_AT:-24}" ] && compact=1
    # A pane this short has room for the title, the table and the keys and
    # nothing else. Everything that is context rather than content goes.
    [ "$H" -lt "${PITCREW_MICRO_AT:-12}" ] && { compact=1; micro=1; }
    local gap=$'\e[K\n\e[K\n' gapn=2
    [ $compact = 1 ] && { gap=$'\e[K\n'; gapn=1; }
    if [ $compact = 1 ]; then
      sw=$(( W / 8 )); [ $sw -lt 8 ] && sw=8; [ $sw -gt 20 ] && sw=20
    else
      sw=$(( W / 5 )); [ $sw -lt 12 ] && sw=12; [ $sw -gt 40 ] && sw=40
    fi
    ROW_COMP=()
    SCROLL_ABOVE=0; SCROLL_BELOW=0
    frame=""; ln=0
    printf -v ts '%(%H:%M:%S)T' -1        # builtin strftime — no `date` fork

    # ── title rule ──
    printf -v line '%b──%b %b%s%b %blive%b %b' "$C_FAINT" "$RESET" "$C_ACCENT$BOLD" "${PITCREW_PROJECT_NAME:-pitcrew}" "$RESET" "$C_MUTED" "$RESET" "$C_FAINT"
    # visible chrome: "── " + name + " live " + rule + " " + ts + " ──", and
    # one column short of the edge on purpose. Auto-wrap is off so a full-width
    # line is legal, but a printable character in the very last cell is the
    # classic place for a terminal (tmux especially) to disagree about whether
    # the cursor wrapped — and a single wrong wrap scrolls the whole frame.
    rule_len=$((W - 14 - ${#PITCREW_PROJECT_NAME} - ${#ts})); [ $rule_len -lt 0 ] && rule_len=0
    r=""; while [ ${#r} -lt $rule_len ]; do r+="─"; done
    frame+="$line$r $ts ──$RESET"$'\e[K\n'; ln=$((ln + 1))

    # ── the verdict ──
    # The first line under the title, because it is the first question: can I
    # go back to what I was doing? Everything else on this screen is evidence
    # for it. A count of what is up is not an answer — "9 up · 1 crashed" still
    # leaves the reading to you, and the one that matters is the 1.
    if [ $micro = 0 ]; then
      diag_verdict_line
      local vline=$R vhint="" vwidth=$(( 5 + ${#DIAG_HEADLINE} ))
      if [ "$DIAG_N" -gt 0 ]; then
        printf -v vhint '   %b%b d %b%b for details%b' \
          "$C_CAP" "$C_TEXT" "$RESET" "$C_FAINT" "$RESET"
        [ $(( vwidth + 16 )) -gt "$W" ] && vhint=""
      fi
      frame+="  $vline$vhint"$'\e[K\n'; ln=$((ln + 1))
    fi
    # The title and the verdict are lines of their own now, so what is left of
    # the gap is only the blank spacer under them: one row when there is room,
    # none when the window is short. Getting this count wrong does not look
    # wrong — it silently pushes the pinned footer off the bottom of the frame.
    if [ "$gapn" -gt 1 ]; then frame+=$'\e[K\n'; ln=$((ln + 1)); fi

    # ── system gauges, as history rather than a single instant ──
    # Scale floors of 100 and total-RAM make these absolute rather than
    # auto-scaled: 4% CPU should look like 4%, not like a full bar.
    if [ $micro = 0 ]; then
      local cpuline used="" total="" have_mem=0
      if [ -n "$SYS_MEM_TOTAL_KB" ] && [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ]; then
        have_mem=1
        human $(( SYS_MEM_USED_KB * 1024 )); used=$HUMAN
        human $(( SYS_MEM_TOTAL_KB * 1024 )); total=$HUMAN
      fi
      # The two gauges are a fluid column between fixed labels and fixed
      # numbers, so the sparkline is what has to give when the window narrows
      # — and when the two fold onto ONE line it has to give twice as much.
      # This used to be a fraction of the width with a floor under it, which
      # is fine until the floor plus the numbers is wider than the terminal:
      # at 38 columns the folded line ran off the edge mid-figure.
      #   CPU:  "   CPU " + spark + " " + "100%"        = 12 + spark
      #   RAM:  "   RAM " + spark + " 9.2G / 31.0G"     = 11 + spark + numbers
      local room=$W fixed=$(( 12 + 11 + ${#used} + ${#total} ))
      if [ $compact = 1 ]; then
        sw=$(( (room - fixed) / 2 ))
      else
        sw=$(( room - 12 )); [ $(( room - 11 - ${#used} - ${#total} )) -lt "$sw" ] \
          && sw=$(( room - 11 - ${#used} - ${#total} ))
        [ "$sw" -gt $(( W / 5 )) ] && sw=$(( W / 5 ))
      fi
      [ "$sw" -gt 40 ] && sw=40
      [ "$sw" -lt 4 ] && sw=0          # under four cells it is a smudge, not a trend

      # A gauge is a LEVEL, and a bar is how a level reads at a glance: the
      # filled part is the number. Drawn as history instead, 1% CPU and 100%
      # CPU both came out as a full-width line — every sample sat at the same
      # height, so the shape said nothing and the only real information was
      # the figure printed after it.
      pct_color "${SYS_CPU_PCT:-0}"
      if [ "$sw" -gt 0 ]; then
        if [ "$PITCREW_GAUGE" = bar ]; then bar "${SYS_CPU_PCT:-0}" "$sw"
        else spark "$HIST_SYS_CPU" "$sw" 100 "$PCOL" abs; fi
        printf -v cpuline '   %bCPU%b %s %b%3s%b%b%%%b' "$C_MUTED" "$RESET" "$R" \
          "$C_TEXT" "${SYS_CPU_PCT:-0}" "$RESET" "$C_MUTED" "$RESET"
      else
        printf -v cpuline '   %bCPU%b %b%3s%b%b%%%b' "$C_MUTED" "$RESET" \
          "$C_TEXT" "${SYS_CPU_PCT:-0}" "$RESET" "$C_MUTED" "$RESET"
      fi
      if [ "$have_mem" = 1 ]; then
        local mpct=$(( SYS_MEM_USED_KB * 100 / SYS_MEM_TOTAL_KB ))
        pct_color "$mpct"
        R=""
        if [ "$sw" -gt 0 ]; then
          if [ "$PITCREW_GAUGE" = bar ]; then bar "$mpct" "$sw"
          else spark "$HIST_SYS_MEM" "$sw" "$SYS_MEM_TOTAL_KB" "$PCOL" abs; fi
          R="$R "
        fi
        printf -v line '   %bRAM%b %s%b%s%b %b/%b %b%s%b' "$C_MUTED" "$RESET" "$R" \
          "$C_TEXT" "$used" "$RESET" "$C_FAINT" "$RESET" "$C_MUTED" "$total" "$RESET"
      else
        printf -v line '   %bRAM%b %bunavailable on this OS%b' "$C_MUTED" "$RESET" "$C_FAINT" "$RESET"
      fi
      # compact folds them onto one line; the RAM gauge is worth more than the
      # blank row under it
      if [ $compact = 1 ]; then
        frame+="$cpuline$line"$'\e[K\n'; ln=$((ln + 1))
      else
        frame+="$cpuline"$'\e[K\n'"$line"$'\e[K\n\e[K\n'; ln=$((ln + 3))
      fi
    fi

    # ── deps, folded onto their own rule line ──
    # Six deps used to run 40 columns past the right edge, and with auto-wrap
    # off the terminal ate them without a trace. Wrap onto a continuation line;
    # when there are no rows to spare, say how many did not fit.
    if [ ${#PITCREW_DEPS[@]} -gt 0 ] && [ $micro = 0 ]; then
      local dep dline dvis dshown=0 dtotal=${#PITCREW_DEPS[@]}
      local DEPS_INDENT_W=10        # visible width of "── deps   "
      printf -v dline '%b──%b %b%s%b   ' "$C_FAINT" "$RESET" "$C_TEXT$BOLD" "deps" "$RESET"
      dvis=$DEPS_INDENT_W
      for dep in "${PITCREW_DEPS[@]}"; do
        if [ $(( dvis + ${#dep} + 5 )) -gt "$W" ]; then
          # nothing on this line yet means it will never fit — truncate, do not
          # loop forever widening a line the terminal cannot hold
          if [ $compact = 1 ] || [ "$dvis" -le "$DEPS_INDENT_W" ]; then
            printf -v R '%b+%s%b' "$C_MUTED" "$(( dtotal - dshown ))" "$RESET"
            dline+="$R"; break
          fi
          frame+="$dline"$'\e[K\n'; ln=$((ln + 1))
          printf -v dline '%*s' "$DEPS_INDENT_W" ''; dvis=$DEPS_INDENT_W
        fi
        state_icon "${SNAP_DEP[$dep]:-down}"
        dline+="$R ${dep}   "
        dvis=$(( dvis + ${#dep} + 5 )); dshown=$(( dshown + 1 ))
      done
      frame+="$dline$gap"; ln=$((ln + gapn))
    fi

    # ── services ──
    summary_line
    printf -v line '%b──%b %b%s%b%s' "$C_FAINT" "$RESET" "$C_TEXT$BOLD" "services" "$RESET" "$R"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    # Column headers over an empty table are pure noise — they were the worst
    # thing about the first screen anyone sees.
    local empty=0
    # "nothing is running" is only the right thing to say on a resting
    # dashboard. Once you are filtering or marking you are choosing what to
    # start, and hiding the rows is exactly backwards.
    local nmarked=0 _mc
    for _mc in "${PITCREW_COMPS[@]}"; do [ -n "${MARKED[$_mc]:-}" ] && nmarked=$((nmarked + 1)); done
    [ "${SUM_UP:-0}" -eq 0 ] && [ "${SUM_STARTING:-0}" -eq 0 ] && [ "${SUM_EXTERNAL:-0}" -eq 0 ] \
      && [ -z "$FILTER" ] && [ "$nmarked" -eq 0 ] && empty=1

    cell_header "$bw"; local chdr=$R
    if [ $empty = 1 ] || [ $micro = 1 ]; then :
    elif [ $narrow = 1 ]; then
      printf -v line '%b%-*.*s%s%b' "$C_MUTED" "$PREFIX_W" "$PREFIX_W" "   service" "$chdr" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    else
      printf -v line '%b%-*s%-*s%*s%s%b' "$C_MUTED" \
        "$PREFIX_W" "   app" "$((CELL_FIXED_W + bw))" "backend" "$CELL_GAP_W" "" "frontend" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
      printf -v line '%*s%s%*s%s' "$PREFIX_W" "" "$chdr" "$CELL_GAP_W" "" "$chdr"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    fi

    # Rows left for services and any expanded trees, keeping the footer on
    # screen. The footer is blank + legend + status + toast + keys; compact
    # drops the blank and the legend, so it is three rows instead of five.
    local foot=5; [ $compact = 1 ] && foot=3; [ $micro = 1 ] && foot=2
    avail=$(( H - ln - foot ))
    [ $avail -lt 0 ] && avail=0

    # A first run used to show twelve rows of dots under a table header. Say
    # what to do instead, centred on its own width rather than a shared guess.
    # An empty state is centred in the space it has, both ways — it is the
    # whole content of the screen at that moment, and the footer is pinned to
    # the bottom, so left at the top of the table area it reads as a stray
    # line of text under a header rather than as the thing you are meant to
    # look at. _vcentre spends half the free rows above it.
    _vcentre() { # $1 rows the message needs
      local pad=$(( (avail - $1) / 2 ))
      while [ "$pad" -gt 0 ]; do
        frame+=$'\e[K\n'; ln=$((ln + 1)); avail=$((avail - 1)); pad=$((pad - 1))
      done
    }
    if [ ${#VIEW_APPS[@]} -eq 0 ] && [ -n "$FILTER" ]; then
      local nomatch
      printf -v nomatch '%bnothing matches%b %b %s %b' "$C_MUTED" "$RESET" "$C_CAP$C_TEXT" "$FILTER" "$RESET"
      _vcentre 1
      centre "$W" $(( 16 + ${#FILTER} + 2 )) "$nomatch"
      frame+="$R"$'\e[K\n'; ln=$((ln + 1))
      avail=$(( avail - 1 ))
    elif [ $empty = 1 ]; then
      local msg1 msg2
      printf -v msg1 '%b%s%b' "$C_TEXT$BOLD" "nothing is running yet" "$RESET"
      printf -v msg2 '%bpress%b %b m %b %bfor the menu, or run%b %b pitcrew start %b' \
        "$C_MUTED" "$RESET" "$C_CAP$C_TEXT" "$RESET" \
        "$C_MUTED" "$RESET" "$C_CAP$C_TEXT" "$RESET"
      _vcentre 3
      centre "$W" 22 "$msg1"; frame+="$R"$'\e[K\n'; ln=$((ln + 1))
      frame+=$'\e[K\n'; ln=$((ln + 1))
      centre "$W" 46 "$msg2"; frame+="$R"$'\e[K\n'; ln=$((ln + 1))
      avail=$(( avail - 3 ))
    else
    scroll_to_selection "$avail"
    local drawn=0
    for ((i = ROW_OFF; i < ${#VIEW_APPS[@]}; i++)); do
      [ $avail -le 0 ] && break
      drawn=$(( drawn + 1 ))
      app=${VIEW_APPS[i]}
      local nm=$C_SUBTLE selected=0
      if [ "${VIEW[$SEL]:-}" = "be-$app" ] || [ "${VIEW[$SEL]:-}" = "fe-$app" ]; then
        selected=1; nm="$C_TEXT$BOLD"
      fi
      rail_color "$app"
      local label=$app mark=" "
      [ -n "${APP_ICON[$app]:-}" ] && label="${APP_ICON[$app]} $app"
      [ -n "${MARKED[be-$app]:-}${MARKED[fe-$app]:-}" ] && mark="${C_ACCENT2}✓${RESET}"
      local nw=$(( PREFIX_W - 4 ))
      if [ $narrow = 1 ]; then
        # one component per row, so the role moves into the label — and the
        # selection is per COMPONENT here, not per app: one of these two rows
        # is selected, and highlighting both would be a lie about what the
        # action keys are pointing at.
        local nrow rc rsel rnm
        for rc in "be-$app" "fe-$app"; do
          [ -n "${SNAP_STATE[$rc]:-}" ] || continue
          # one app is TWO rows here, and the budget was only checked before
          # the app — so on a window with one row left the second component
          # was drawn anyway and pushed the key hints off the bottom
          [ $avail -le 0 ] && break
          rsel=0; rnm=$C_SUBTLE
          [ "${VIEW[$SEL]:-}" = "$rc" ] && { rsel=1; rnm="$C_TEXT$BOLD"; }
          rail_color "$app"
          _row_label "$label" "${rc:0:2}" "$nw"
          printf -v nrow '%b▐%b%b %b%s%b ' "$RAILC" "$RESET" "$mark" "$rnm" "$R" "$RESET"
          comp_cell "$rc" "$bw"; nrow+="$R"
          [ $rsel = 1 ] && { _band_row "$nrow" $(( PREFIX_W + CELL_FIXED_W + bw )) "$W"; nrow=$R; }
          frame+="$nrow"$'\e[K\n'; ln=$((ln + 1)); avail=$((avail - 1))
          ROW_COMP[$ln]="$app"
        done
        continue
      fi
      _row_label "$label" "" "$nw"
      printf -v line '%b▐%b%b %b%s%b ' "$RAILC" "$RESET" "$mark" "$nm" "$R" "$RESET"
      comp_cell "be-$app" "$bw"; line+="$R"
      comp_cell "fe-$app" "$bw"; line+="  $R"
      [ "$selected" = 1 ] && \
        { _band_row "$line" $(( PREFIX_W + CELL_GAP_W + 2 * (CELL_FIXED_W + bw) )) "$W"; line=$R; }
      frame+="$line"$'\e[K\n'
      ln=$((ln + 1)); avail=$((avail - 1))
      ROW_COMP[$ln]="$app"

      # expanded process tree — the data is already in the snapshot, so this
      # costs nothing extra to render
      for c in "be-$app" "fe-$app"; do
        [ -n "${EXPANDED[$c]:-}" ] || continue
        _tree_sorted "$c"
        local p k=0 tot=${#TREE_SORTED[@]}
        for p in "${TREE_SORTED[@]}"; do
          [ $avail -le 0 ] && break
          k=$((k + 1))
          local branch="├"; [ $k -eq $tot ] && branch="└"
          human "${SNAP_PROC_RSS[$p]:-0}"
          printf -v line '   %b│%b   %b%s%b %b%-6s%b %b%-18s%b %b%6s%b%b%s%b %b%3s%b%b%%%b' \
            "$C_FAINT" "$RESET" "$C_FAINT" "$branch" "$RESET" \
            "$C_MUTED" "$p" "$RESET" "$C_SUBTLE" "${SNAP_PROC_CMD[$p]:-?}" "$RESET" \
            "$C_TEXT" "${HUMAN%[GM]}" "$RESET" "$C_MUTED" "${HUMAN: -1}" "$RESET" \
            "$C_TEXT" "${SNAP_PROC_CPU[$p]:-0}" "$RESET" "$C_MUTED" "$RESET"
          frame+="$line"$'\e[K\n'
          ln=$((ln + 1)); avail=$((avail - 1))
        done
      done
    done
    SCROLL_ABOVE=$ROW_OFF
    SCROLL_BELOW=$(( ${#VIEW_APPS[@]} - ROW_OFF - drawn ))
    [ "$SCROLL_BELOW" -lt 0 ] && SCROLL_BELOW=0
    fi

    # ── the footer sticks to the bottom ──
    # Six services in a thirty-row window used to leave the legend and the key
    # hints floating in the middle of the screen with a third of the terminal
    # blank underneath them, and every started service shoved them further
    # down. Pad the table out instead: the keys live on the last row, where
    # they stay put whatever the table is doing — and the eye learns one place
    # to look for them.
    local pad=$(( H - foot - ln ))
    while [ "$pad" -gt 0 ]; do frame+=$'\e[K\n'; ln=$((ln + 1)); pad=$((pad - 1)); done

    if [ $compact = 0 ]; then
      frame+=$'\e[K\n'; ln=$((ln + 1))
      # Auto-wrap is off, so anything wider than the terminal is silently
      # truncated by it — drop legend entries that will not fit instead.
      local leg="   " lg vis=3
      for lg in "● up" "◐ starting" "✗ crashed" "◇ not ours" "○ down" "· n/a" "⚡ log errors" "$FRAME_TAG"; do
        [ $(( vis + ${#lg} + 2 )) -gt "$W" ] && break
        leg+="$lg  "; vis=$(( vis + ${#lg} + 2 ))
      done
      printf -v line '%b%s%b' "$C_FAINT" "$leg" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    fi

    local ws="" nmark=0 mc
    for mc in "${PITCREW_COMPS[@]}"; do [ -n "${MARKED[$mc]:-}" ] && nmark=$((nmark + 1)); done
    [ "$SORT" != name ] && ws+="   ${C_MUTED}sort${RESET} ${C_TEXT}${SORT}${RESET}"
    [ -n "$FILTER" ]    && ws+="   ${C_MUTED}filter${RESET} ${C_CAP}${C_TEXT} ${FILTER} ${RESET}"
    [ "$nmark" -gt 0 ]  && ws+="   ${C_ACCENT2}✓ ${nmark} marked${RESET}"
    [ "$SCROLL_ABOVE" -gt 0 ] && ws+="   ${C_MUTED}↑ ${SCROLL_ABOVE} above${RESET}"
    [ "$SCROLL_BELOW" -gt 0 ] && ws+="   ${C_MUTED}↓ ${SCROLL_BELOW} below${RESET}"
    if [ -n "$ws" ]; then frame+="$ws"$'\e[K\n'; else frame+=$'\e[K\n'; fi
    ln=$((ln + 1))

    if [ -n "$TOAST" ] && [ $(( ${SNAP_NOW_S:-0} - TOAST_AT )) -lt 5 ]; then
      printf -v line '   %s' "$TOAST"
    else
      TOAST=""; line=""
    fi
    [ $micro = 0 ] && { frame+="$line"$'\e[K\n'; ln=$((ln + 1)); }
    # key caps: an inverse-video cap and a dim label reads as an app footer
    # rather than as a line of shell output
    line=" "
    local kc cap lbl kvis=1 addw
    for kc in "↑↓:select" "␣:mark" "a:start" "s:stop" "r:restart" "⏎:tree" \
            "d:diagnose" "/:filter" "o:sort" "l:logs" "e:errors" "p:project" "m:menu" "q:quit"; do
      cap=${kc%%:*}; lbl=${kc#*:}
      addw=$(( ${#cap} + 2 + 1 + ${#lbl} + 2 ))     # " cap " + " " + label + "  "
      [ $(( kvis + addw )) -gt "$W" ] && break
      line+="${C_CAP}${C_TEXT} ${cap} ${RESET}${C_MUTED} ${lbl}${RESET}  "
      kvis=$(( kvis + addw ))
    done
    frame+="$line"$'\e[K'

  fit_frame "$frame" "$W" "$H"
  FRAME=$FIT
  return 0
}

# ── overflow: hidden ────────────────────────────────────────────────────────
# The frame is painted from the home position with auto-wrap off, which makes
# both directions unforgiving. One row too many scrolls the alt screen and
# every repaint after it lands a row off — the display never recovers. One
# column too many is quieter and worse: the terminal simply eats the tail of
# the row, which is how a stale window size turned the "frontend" header into
# "f" and cut every second cell in half.
#
# Every widget above already fits itself to the width, and that is where the
# layout decisions belong — this is the guard that makes a mistake up there
# cost a truncated row instead of a corrupted screen.
fit_frame() { # $1 frame, $2 cols, $3 rows → FIT
  local w=$2 h=$3 i n out="" seg
  local -a rows
  # mapfile, not `while read`: one builtin over the whole frame instead of a
  # builtin call per row, and unlike splitting on $IFS it keeps blank rows —
  # which the pinned footer depends on.
  mapfile -t rows <<< "$1"
  n=${#rows[@]}; [ "$n" -gt "$h" ] && n=$h
  for ((i = 0; i < n; i++)); do
    seg=${rows[i]}
    [ "$i" -gt 0 ] && out+=$'\n'
    if [ "${#seg}" -le "$w" ]; then out+="$seg"; continue; fi
    fit_line "$seg" "$w"; out+="$R"
  done
  FIT=$out
  return 0
}

# → R: $1 cut to $2 visible columns, with its escape sequences intact.
#
# Two things make this affordable enough to run on every row of every frame.
#
# It splits on ESC and walks the pieces. The obvious version — step through
# the string a character at a time, or chop the head off it in a loop —
# re-copies the whole row on every step, so a row with thirty colour changes
# costs thirty copies of itself. That version was measurable: 38ms on a frame
# that takes 12.
#
# And it MEASURES before it cuts. Almost every row already fits; this guard is
# here for the one that does not. Measuring is a length check per piece, while
# cutting reassembles the row piece by piece, so the row that fits pays for
# neither.
#
# (An earlier attempt measured with one extglob substitution — strip every
# `ESC [ params letter` and take what is left. It is the obvious way to write
# it and it HANGS: bash backtracks that pattern over a 400-character row for
# long enough to stall the dashboard. Do not reintroduce it.)
fit_line() {
  local s=$1 budget=$2 i n txt head vis=0 cut=-1 keep=0
  local -a parts
  local IFS=$'\e'
  # the split on $IFS is the point here, and noglob keeps a service name
  # containing * from being expanded into filenames on the way through
  set -f                                       # a name containing * must not glob
  # shellcheck disable=SC2206
  parts=($s)
  set +f
  n=${#parts[@]}
  for ((i = 0; i < n; i++)); do
    txt=${parts[i]}
    if [ "$i" -gt 0 ]; then
      # every sequence the frame emits is a CSI: "[", parameters, then a final
      # byte, which is its first alphabetic character. Colour costs no columns.
      head=${txt%%[a-zA-Z]*}
      [ "${#head}" -ge "${#txt}" ] && continue        # unterminated: leave it alone
      txt=${txt:$(( ${#head} + 1 ))}
    fi
    if [ $(( vis + ${#txt} )) -le "$budget" ]; then
      vis=$(( vis + ${#txt} )); continue
    fi
    cut=$i; keep=$(( budget - vis ))                  # visible chars to keep in THIS piece
    break
  done
  if [ "$cut" -lt 0 ]; then R=$s; return 0; fi

  local out=""
  for ((i = 0; i < cut; i++)); do
    [ "$i" -gt 0 ] && out+=$'\e'
    out+="${parts[i]}"
  done
  txt=${parts[cut]}
  if [ "$cut" -gt 0 ]; then
    head=${txt%%[a-zA-Z]*}
    out+=$'\e'"${head}${txt:${#head}:1}"
    txt=${txt:$(( ${#head} + 1 ))}
  fi
  out+="${txt:0:$keep}"
  # A cut can land between a colour and its RESET, and an unterminated colour
  # bleeds into whatever the terminal draws next — including the shell prompt
  # after the dashboard exits. Close it, and clear the rest of the row.
  R="$out$RESET"$'\e[K'
  return 0
}
