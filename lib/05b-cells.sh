#!/usr/bin/env bash
# lib/05b-cells.sh — one service cell, and the breakpoints that size it.
#
# The width constants and the two builders that read them live together on
# purpose: cell_header and comp_cell must never disagree about how wide a
# column is, and the only way to guarantee that is for both to be built from
# the same table, in the same file.
#
# NOTE ON THE NAME: every file in this group is `05<letter>-`, never `05-`.
# `lib/*.sh` is sourced in glob order, and a UTF-8 collation IGNORES punctuation
# when comparing — so a bare "05-dashboard.sh" would sort AFTER "05b-cells.sh" on a normal
# desktop and before it under LC_ALL=C. This group has top-level code that reads
# variables the previous file sets, so that difference is the difference between
# working and `PITCREW_REFRESH: unbound variable`. Letters sort the same either
# way.
#
# Split out of one 1200-line file. The seams are the ones that were already
# there in comments: the viewport and the working set, the cell/layout
# arithmetic, the frame builder, and the interactive loop. Bash does not care
# what order functions are defined in, and lib/*.sh is sourced in name order,
# so 05a → 05b → 05c → 05d all load before 06.

# not an average.
centre() { # $1 total width, $2 visible width of $3, $3 rendered text → R
  local pad=$(( ($1 - $2) / 2 )); [ $pad -lt 0 ] && pad=0
  printf -v R '%*s%s' "$pad" "" "$3"
}

rail_color() { # $1 app → RAILC
  # Two `local`s on purpose: a variable assigned earlier on the SAME local line
  # is not in scope yet, so s1/s2 would have read the CALLER's $app — the exact
  # trap already documented in lib/07a-start.sh.
  local app=$1
  local s1=${SNAP_STATE[be-$app]:-n/a} s2=${SNAP_STATE[fe-$app]:-n/a} st
  RAILC=$C_FAINT
  for st in "$s1" "$s2"; do
    case "$st" in
      crashed)  RAILC=$C_CRIT; return ;;
      starting) RAILC=$C_WARN ;;
      external) [ "$RAILC" = "$C_FAINT" ] && RAILC=$C_INFO ;;
      up)       [ "$RAILC" = "$C_FAINT" ] && RAILC=$C_OK ;;
    esac
  done
}

# ── one service cell ────────────────────────────────────────────────────────
# Each column is its own width, because which columns are DRAWN changes with
# the terminal (see layout_for_width) and a single fixed total cannot describe
# a row that has dropped one. cell_header and comp_cell both build from these,
# so the labels can never drift away from the numbers under them.
CELL_W_ICON=2        # "● "
CELL_W_PORT=7        # ":8082 " or "n/a    "
CELL_W_RAM=7         # " 893M", or 12 with `render ram cap` (" 1.2G/8G  ")
CELL_W_CPU=5         # "  0%"
CELL_W_ERR=5         # " ⚡7  "
ROW_PREFIX_W=15      # marker(2) + " " + app(11) + " "
ROW_PREFIX_MIN_W=6   # marker(2) + " " + app(2) + " " — nothing below this reads
ROW_PREFIX_MAX_W=26  # past this the name is just leading the eye further from the numbers
CELL_GAP_W=2         # between the backend and frontend cells
CELL_MIN_GRAPH_W=6   # under this a sparkline is decoration, not information
CELL_MAX_GRAPH_W=40  # past this, history stops being readable and the row just sprawls

# ── breakpoints ─────────────────────────────────────────────────────────────
# One place decides what the frame is drawing, so the column header, the rows
# and the selection band can never disagree about it.
#
# Two things vary with the width, exactly as they do in a responsive page: how
# many cells fit on a row, and which columns inside a cell survive. The tiers,
# widest first:
#
#   xl  ≥ 160   two cells, and the graph stops growing — a 300-column window
#               should buy more history, not a row that sprawls off the edge
#   lg  ≥ 110   backend and frontend side by side
#   md  ≥  62   one component per row — one readable cell beats two squeezed
#               ones — with a sparkline
#   sm  ≥  46   no graph. Under ~50 columns the sparkline pushes the port and
#               the numbers off the right edge, and with auto-wrap off the
#               terminal drops them silently. Losing history is cheap; losing
#               "which port, how much RAM" is not.
#   xs  <  46   the same cascade continues into the numbers themselves: the
#               error count goes, then CPU, then RAM, each buying columns back
#               for the name. A 30-column split pane still says WHICH service
#               is on WHICH port, which is the irreducible content of this row.
#
# The cascade is a priority order, not a table of magic numbers: drop the
# least important column, re-measure, drop the next. The tier name is what
# comes OUT of it, and exists so the tests and the header can name what they
# are looking at.
layout_for_width() { # $1 W → LAYOUT, TIER, GRAPH_W, PREFIX_W, CELL_FIXED_W, CELL_RAM/CPU/ERR
  local w=$1 cells=2
  PREFIX_W=$ROW_PREFIX_W
  CELL_RAM=1; CELL_CPU=1; CELL_ERR=1
  # `render ram cap` spells out what the colour already implies, and needs the
  # room for it. Set before any width is added up below.
  [ "${PITCREW_RAM_CELL:-value}" = cap ] && CELL_W_RAM=12 || CELL_W_RAM=7
  [ "$w" -ge "${PITCREW_NARROW_AT:-110}" ] || cells=1

  # Drop columns until the row's fixed part fits, cheapest loss first. The
  # graph is not in this list: it is the flexible column that soaks up
  # whatever is left over, so it shrinks on its own before anything is lost.
  local dropped
  for dropped in err cpu ram; do
    _cell_fixed_w
    [ $(( PREFIX_W + cells * CELL_FIXED_W + (cells - 1) * CELL_GAP_W )) -le "$w" ] && break
    case "$dropped" in
      err) CELL_ERR=0 ;;
      cpu) CELL_CPU=0 ;;
      ram) CELL_RAM=0 ;;
    esac
  done
  _cell_fixed_w

  # Whatever the fixed columns did not take is the graph's, split between the
  # cells. Under CELL_MIN_GRAPH_W there is no graph worth drawing, and the
  # room goes back to the name.
  GRAPH_W=$(( (w - PREFIX_W - cells * CELL_FIXED_W - (cells - 1) * CELL_GAP_W) / cells ))
  [ "$GRAPH_W" -gt "$CELL_MAX_GRAPH_W" ] && GRAPH_W=$CELL_MAX_GRAPH_W
  if [ "$GRAPH_W" -lt "$CELL_MIN_GRAPH_W" ]; then
    GRAPH_W=0
    # give the name column whatever the cell leaves, so the row still ends
    # inside the terminal instead of being cut off by it
    PREFIX_W=$(( w - cells * CELL_FIXED_W - (cells - 1) * CELL_GAP_W ))
    [ "$PREFIX_W" -gt "$ROW_PREFIX_W" ]     && PREFIX_W=$ROW_PREFIX_W
    [ "$PREFIX_W" -lt "$ROW_PREFIX_MIN_W" ] && PREFIX_W=$ROW_PREFIX_MIN_W
  fi

  # Whatever is STILL left over once the graph has hit its cap goes to the
  # name, up to a limit of its own. A wide window should buy something —
  # service names that are not elided — and a row that stops two thirds of the
  # way across the terminal looks like a bug even when the numbers are right.
  # Past both caps the table simply stops growing: this is a max-width
  # container, not a stretched one.
  local slack=$(( w - PREFIX_W - cells * (CELL_FIXED_W + GRAPH_W) - (cells - 1) * CELL_GAP_W ))
  if [ "$slack" -gt 0 ] && [ "$PREFIX_W" -lt "$ROW_PREFIX_MAX_W" ]; then
    PREFIX_W=$(( PREFIX_W + slack ))
    [ "$PREFIX_W" -gt "$ROW_PREFIX_MAX_W" ] && PREFIX_W=$ROW_PREFIX_MAX_W
  fi

  if [ "$cells" = 2 ]; then
    LAYOUT=wide
    TIER=lg; [ "$w" -ge "${PITCREW_XL_AT:-160}" ] && TIER=xl
  else
    LAYOUT=narrow
    TIER=md
    [ "$GRAPH_W" -eq 0 ] && { LAYOUT=tiny; TIER=sm; }
    [ "$CELL_RAM$CELL_CPU$CELL_ERR" = 111 ] || TIER=xs
  fi
  return 0
}

_cell_fixed_w() { # → CELL_FIXED_W: one cell minus its graph, at the current column set
  CELL_FIXED_W=$(( CELL_W_ICON + CELL_W_PORT ))
  [ "$CELL_RAM" = 1 ] && CELL_FIXED_W=$(( CELL_FIXED_W + CELL_W_RAM ))
  [ "$CELL_CPU" = 1 ] && CELL_FIXED_W=$(( CELL_FIXED_W + CELL_W_CPU ))
  [ "$CELL_ERR" = 1 ] && CELL_FIXED_W=$(( CELL_FIXED_W + CELL_W_ERR ))
  return 0
}

# Set once so the file is never read with these unset (layout_for_width runs
# before any row is drawn, but a helper called from a test should not have to
# know that).
layout_for_width 120

cell_header() { # $1 graph width → R, exactly CELL_FIXED_W + $1 wide
  local g="" h
  [ "$1" -gt 0 ] && printf -v g '%-*s' "$1" "graph"
  printf -v h '%*s%-*s%s' "$CELL_W_ICON" "" "$(( CELL_W_PORT ))" "port" "$g"
  if [ "$CELL_RAM" = 1 ]; then
    [ "${PITCREW_RAM_CELL:-value}" = cap ] && printf -v h '%s %11s' "$h" "ram / cap" \
                                           || printf -v h '%s %6s' "$h" "ram"
  fi
  [ "$CELL_CPU" = 1 ] && printf -v h '%s %4s' "$h" "cpu"
  [ "$CELL_ERR" = 1 ] && printf -v h '%s %-4s' "$h" ""
  printf -v R '%b%s%b' "$C_MUTED" "$h" "$RESET"
}

comp_cell() { # $1 comp, $2 graph width (0 = no graph column) → R: one aligned cell
  # Every branch below appends the SAME columns in the SAME order — icon,
  # port, graph, ram, cpu, err — because a cell that skips one silently
  # shifts everything to its right by that column's width, and in the wide
  # layout that shift lands in the middle of the neighbouring service.
  local c=$1 gw=$2 st port cur app role cell pct i
  st=${SNAP_STATE[$c]:-n/a}
  app=${c#??-}; role=${c:0:2}
  if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
  cur=${SNAP_RSS[$c]:-}

  state_icon "$st"; cell="$R "
  if [ "$st" = n/a ]; then
    printf -v R '%b%-6s%b ' "$C_FAINT" "n/a" "$RESET"
  else
    printf -v R '%b:%-5s%b ' "$C_MUTED" "${port:--}" "$RESET"
  fi
  cell+="$R"

  if [[ "$cur" =~ ^[0-9]+$ ]] && [ "$cur" -gt 0 ]; then
    # Height and colour answer two different questions, and the graph is only
    # readable when each one has its own channel:
    #
    #   height  is this MOVING? — scaled to the service's own recent range, so
    #           a leak climbs and a steady service stays a flat line. Scaled
    #           from zero instead, a service holding at 1.0G puts every sample
    #           at the maximum and the graph saturates into a solid block.
    #   colour  how close to the cap am I? — the same colour as the RAM figure
    #           beside it, because that is the same question.
    #
    # `scale cap` swaps the height back to absolute-against-the-cap for anyone
    # who wants it, and hands the colour back to the cool-to-hot ramp.
    pct=$(( cur * 100 / ${COMP_MAX_B[$c]:-1} ))
    pct_color "$pct"
    if [ "$gw" -gt 0 ]; then
      case "$PITCREW_GRAPH" in
        bar) bar "$pct" "$gw" ;;
        *)   if [ "$PITCREW_GRAPH_SCALE" = cap ]; then
               spark "${HIST_MEM[$c]:-}" "$gw" "${COMP_MAX_B[$c]:-67108864}" "" abs
             else
               spark "${HIST_MEM[$c]:-}" "$gw" 67108864 "$PCOL" range
             fi ;;
      esac
      cell+="$R"
    fi
    if [ "$CELL_RAM" = 1 ]; then
      human "$cur"
      # units are chrome: bright value, dim unit
      printf -v R ' %b%5s%b%b%s%b' \
        "$PCOL" "${HUMAN%[GM]}" "$RESET" "$C_MUTED" "${HUMAN: -1}" "$RESET"
      cell+="$R"
      if [ "${PITCREW_RAM_CELL:-value}" = cap ]; then
        printf -v R '%b/%-4s%b' "$C_FAINT" "${COMP_MAX_LABEL[$c]:-?}" "$RESET"
        cell+="$R"
      fi
    fi
    if [ "$CELL_CPU" = 1 ]; then
      printf -v R ' %b%3s%b%b%%%b' "$C_TEXT" "${SNAP_CPU[$c]:-0}" "$RESET" "$C_MUTED" "$RESET"
      cell+="$R"
    fi
  else
    if is_external "$c"; then
      # %*.*s, not %*s: "external" is 8 columns and the graph slot can be 6
      [ "$gw" -gt 0 ] && {
        printf -v R '%b%*.*s%b' "$DIM$GREY" "$gw" "$gw" "external" "$RESET"; cell+="$R"; }
      [ "$CELL_RAM" = 1 ] && { printf -v R ' %6s' "—"; cell+="$R"; }
      [ "$CELL_CPU" = 1 ] && { printf -v R ' %4s' "—"; cell+="$R"; }
    elif [ "$st" = crashed ] && [ -n "${SNAP_EXIT[$c]:-}" ]; then
      # the graph area is empty for a dead service anyway — spend it on the one
      # thing you want to know, which is how it died
      local reason
      printf -v reason 'exit %s' "${SNAP_EXIT[$c]}"
      [ "${SNAP_EXIT[$c]}" -gt 128 ] 2>/dev/null && \
        printf -v reason 'signal %s' "$(( ${SNAP_EXIT[$c]} - 128 ))"
      [ -n "${SNAP_EXIT_AT[$c]:-}" ] && [ "${SNAP_EXIT_AT[$c]}" -gt 0 ] 2>/dev/null && \
        printf -v reason '%s · %(%H:%M:%S)T' "$reason" "${SNAP_EXIT_AT[$c]}"
      printf -v R '%b%-*.*s%b' "$RED" "$gw" "$gw" " $reason" "$RESET"
      cell+="$R"
      [ "$CELL_RAM" = 1 ] && { printf -v R ' %6s' ""; cell+="$R"; }
      [ "$CELL_CPU" = 1 ] && { printf -v R ' %4s' ""; cell+="$R"; }
    elif [ "$st" = n/a ]; then
      # NOT the baseline below. "down" is a component that exists and is not
      # running — an empty chart is the truth. "n/a" is an app with no frontend
      # at all, and drawing a chart there is a claim about something that does
      # not exist. The asymmetric-role model is the whole point; the two must
      # not look identical.
      printf -v R '%*s' "$gw" ""
      cell+="$R"
      [ "$CELL_RAM" = 1 ] && { printf -v R ' %6s' ""; cell+="$R"; }
      [ "$CELL_CPU" = 1 ] && { printf -v R ' %4s' ""; cell+="$R"; }
    else
      # a faint baseline, not a lone dot: the column reads as an empty chart
      # rather than as something broken
      local base=""
      for ((i = 0; i < gw; i++)); do base+="▁"; done
      printf -v R '%b%s%b' "$C_FAINT" "$base" "$RESET"
      cell+="$R"
      [ "$CELL_RAM" = 1 ] && { printf -v R ' %6s' ""; cell+="$R"; }
      [ "$CELL_CPU" = 1 ] && { printf -v R ' %4s' ""; cell+="$R"; }
    fi
  fi

  if [ "$CELL_ERR" = 1 ]; then
    if [ "${ERR_COUNT[$c]:-0}" -gt 0 ]; then
      printf -v R ' %b%-4s%b' "$RED" "⚡${ERR_COUNT[$c]}" "$RESET"
    else
      printf -v R ' %-4s' ""
    fi
    cell+="$R"
  fi
  R="$cell"
}

# The name column is the first thing a narrow terminal squeezes, and it used
# to be squeezed from the wrong end: "backoffice be" cut to 11 columns became
# "backoffice " — the name survived whole and the ROLE, the thing that says
# which of the two rows you are looking at, fell off. Elide the name instead;
# it is the half you can still recognise from a prefix.
_row_label() { # $1 name, $2 role suffix ("" for none), $3 width → R, exactly $3 columns
  local text=$1 suffix=$2 w=$3 nw pad=""
  nw=$w
  [ -n "$suffix" ] && nw=$(( w - ${#suffix} - 1 ))
  # no room for both: the role is what tells the two rows apart, so it wins
  [ "$nw" -lt 1 ] && { text=$suffix; suffix=""; nw=$w; }
  [ "${#text}" -gt "$nw" ] && text="${text:0:$(( nw - 1 ))}…"
  # the role reads as part of the name, so it goes right after it — all the
  # slack in a wide name column belongs at the END of the column, not wedged
  # between a service and the role that says which half of it this row is
  [ -n "$suffix" ] && text="$text $suffix"
  # ${#text} counts CHARACTERS and printf's field width counts BYTES, so a
  # name carrying that three-byte ellipsis (or any non-ASCII name) has to be
  # padded by hand — %-*s would stop three columns short and shift the row.
  [ $(( w - ${#text} )) -gt 0 ] && printf -v pad '%*s' $(( w - ${#text} )) ''
  R="$text$pad"
  return 0
}

# Selection is a full-width background band rather than a caret. Every RESET
# inside the row would drop the band, so re-arm it after each one.
_band_row() { # $1 rendered row, $2 its visible width, $3 terminal width → R
  local row=$1 rw=$2 w=$3 sp=""
  if [ -z "$C_BAND" ]; then R=$row; return 0; fi
  row=${row//"$RESET"/"$RESET$C_BAND"}
  while [ ${#sp} -lt $(( w - rw )) ] && [ "$rw" -lt "$w" ]; do sp+=" "; done
  R="$C_BAND$row$sp$RESET"
  return 0
}

# Child processes of one component, heaviest first. Insertion sort over a
# handful of pids — cheaper than forking `sort`, and it runs per open row only.
_tree_sorted() { # $1 comp → TREE_SORTED array
  local c=$1 p i j n
  # shellcheck disable=SC2206  # SNAP_PIDS IS a space-separated pid list
  TREE_SORTED=(${SNAP_PIDS[$c]:-})
  n=${#TREE_SORTED[@]}
  for ((i = 1; i < n; i++)); do
    p=${TREE_SORTED[i]}; j=$((i - 1))
    while [ $j -ge 0 ] && [ "${SNAP_PROC_RSS[${TREE_SORTED[j]}]:-0}" -lt "${SNAP_PROC_RSS[$p]:-0}" ]; do
      TREE_SORTED[j+1]=${TREE_SORTED[j]}; j=$((j - 1))
    done
    TREE_SORTED[j+1]=$p
  done
}

# ── zen rows ────────────────────────────────────────────────────────────────
# Zen is NOT the table with rows taken out of it.
#
# The table costs two header rows, a be/fe column pair and a graph column
# before it says anything, and once the content is "one crashed service" that
# chrome outweighs it: a column header over a single row is noise, and the
# empty `· n/a` frontend cell beside a dead backend spends half the width
# saying nothing. Filtering that layout gives you a wide, mostly-blank table.
#
# So zen draws a LIST. One line per component, each a sentence rather than a
# row of columns you need the header to decode, in a block narrow enough to
# read in one eye movement and centred in the window. No graphs: history is
# what you look at when you are watching something, not when you are deciding
# whether anything needs you, and it is the noisiest thing on the screen.

ZEN_NAMEW=12                   # name column
ZEN_WHATW=9                    # state word — "starting" and "external" are 8
ZEN_DETAILW=26                 # the sentence after it — the longest is
                               # "on its port, not ours" plus an error count
ZEN_BLOCKW=0                   # the block's whole visible width
ZEN_INDENT=2                   # left margin that centres the block
ZEN_VIS=0                      # visible width of the row zen_row just built

zen_metrics() { # $1 terminal width
  # Measured over every CONFIGURED name, not the ones that happen to be
  # visible. Sized to the visible set, the block would shift sideways every
  # time a service crashed or recovered — which is the opposite of calm, and
  # the reason the whole mode exists.
  local w=$1 c n
  ZEN_NAMEW=8
  for c in "${PITCREW_COMPS[@]}" "${PITCREW_DEPS[@]:-}"; do
    [ -n "$c" ] || continue
    n=${#c}; [ "$n" -gt "$ZEN_NAMEW" ] && ZEN_NAMEW=$n
  done
  [ "$ZEN_NAMEW" -gt 22 ] && ZEN_NAMEW=22
  # mark + icon + name + what + detail, with the gaps between them
  ZEN_BLOCKW=$(( 2 + 1 + 2 + ZEN_NAMEW + 2 + ZEN_WHATW + 2 + ZEN_DETAILW ))
  # Room for the margin on BOTH sides, not just the block: clamped to $w and
  # then indented by 2, every row came out two columns past the right edge —
  # and with auto-wrap off the terminal eats those two columns silently.
  [ "$ZEN_BLOCKW" -gt $(( w - 4 )) ] && ZEN_BLOCKW=$(( w - 4 ))
  [ "$ZEN_BLOCKW" -lt 16 ] && ZEN_BLOCKW=16
  ZEN_INDENT=$(( (w - ZEN_BLOCKW) / 2 ))
  [ "$ZEN_INDENT" -lt 2 ] && ZEN_INDENT=2
  # The name and state columns give way before the sentence does: "crashed"
  # with no name is useless, but so is a name with nowhere to say why.
  local fixed=$(( 2 + 1 + 2 + ZEN_NAMEW + 2 + ZEN_WHATW + 2 ))
  ZEN_DETAILW=$(( ZEN_BLOCKW - fixed ))
  if [ "$ZEN_DETAILW" -lt 8 ]; then
    ZEN_NAMEW=$(( ZEN_NAMEW - (8 - ZEN_DETAILW) ))
    [ "$ZEN_NAMEW" -lt 4 ] && ZEN_NAMEW=4
    fixed=$(( 2 + 1 + 2 + ZEN_NAMEW + 2 + ZEN_WHATW + 2 ))
    ZEN_DETAILW=$(( ZEN_BLOCKW - fixed )); [ "$ZEN_DETAILW" -lt 0 ] && ZEN_DETAILW=0
  fi
  return 0
}

# The state word and the sentence that follows it. Split out of zen_row so the
# two-branch component/dependency shape stays readable.
_zen_what() { # $1 comp or dep-NAME → ZWHAT, ZWHATC, ZDETAIL, ZDETAILC
  local key=$1 st n
  if [ "${key:0:4}" = dep- ]; then
    st=${SNAP_DEP[${key#dep-}]:-down}
    ZDETAIL="dependency"; ZDETAILC=$C_FAINT
    case "$st" in
      up) ZWHAT=up;   ZWHATC=$C_OK ;;
      # Ordered above the services in the list because a dead dependency is
      # usually the reason for them — but the ROW does not claim that. Which
      # services actually depend on which container is not modelled, and a
      # confident "likely the cause" beside an unrelated outage is worse than
      # the plain fact.
      *)  ZWHAT=down; ZWHATC=$C_CRIT ;;
    esac
    return 0
  fi
  st=${SNAP_STATE[$key]:-n/a}
  ZDETAIL=""; ZDETAILC=$C_MUTED
  case "$st" in
    up)
      ZWHAT=up; ZWHATC=$C_OK
      # Only marks and filters keep an `up` row in zen, so this row is one you
      # asked to watch. Give it its figures.
      ZDETAIL=""
      if [ -n "${SNAP_SINCE[$key]:-}" ]; then
        dur_human $(( SNAP_NOW_S - SNAP_SINCE[$key] )); ZDETAIL="$DUR"
      fi
      if [ "${SNAP_RSS[$key]:-0}" -gt 0 ] 2>/dev/null; then
        human "${SNAP_RSS[$key]}"; ZDETAIL="${ZDETAIL:+$ZDETAIL  }$HUMAN"
      fi
      [ "${SNAP_CPU_OK:-0}" = 1 ] && ZDETAIL="${ZDETAIL:+$ZDETAIL  }${SNAP_CPU[$key]:-0}%"
      ;;
    starting)
      ZWHAT=starting; ZWHATC=$C_WARN
      if [ -n "${SNAP_SINCE[$key]:-}" ]; then
        dur_human $(( SNAP_NOW_S - SNAP_SINCE[$key] )); ZDETAIL="$DUR so far"
      fi ;;
    crashed)
      ZWHAT=crashed; ZWHATC=$C_CRIT
      # How it died, not that it died — the icon and the word already said
      # that, and "exit 1" versus "killed by signal 9" is the whole question.
      if [ -n "${SNAP_EXIT[$key]:-}" ]; then
        if [ "${SNAP_EXIT[$key]}" -gt 128 ] 2>/dev/null; then
          printf -v ZDETAIL 'signal %s' $(( ${SNAP_EXIT[$key]} - 128 ))
        else
          printf -v ZDETAIL 'exit %s' "${SNAP_EXIT[$key]}"
        fi
        n=${SNAP_EXIT_AT[$key]:-0}
        [ "$n" -gt 0 ] 2>/dev/null && printf -v ZDETAIL '%s · %(%H:%M)T' "$ZDETAIL" "$n"
      fi ;;
    external)
      ZWHAT=external; ZWHATC=$C_INFO
      ZDETAIL="on its port, not ours" ;;
    down)
      ZWHAT=down; ZWHATC=$C_MUTED
      ZDETAIL="not running"; ZDETAILC=$C_FAINT ;;
    *)
      ZWHAT="—"; ZWHATC=$C_FAINT ;;
  esac
  return 0
}

zen_row() { # $1 comp or dep-NAME, $2 1 if selected → R rendered, ZEN_VIS wide
  local key=$1 selected=${2:-0} name row mark errs="" errvis=0 dmax
  local ZWHAT ZWHATC ZDETAIL ZDETAILC

  name=$key
  # Inlined rather than `state_icon "$(comp_state ...)"`: a command
  # substitution is a fork, and this runs once per row per frame.
  local st=${SNAP_STATE[$key]:-n/a}
  [ "${key:0:4}" = dep- ] && { name=${key#dep-}; st=${SNAP_DEP[$name]:-down}; }
  _zen_what "$key"
  state_icon "$st"
  local icon=$R

  mark=" "
  [ -n "${MARKED[$key]:-}" ] && mark="${C_ACCENT2}✓${RESET}"

  # Error counts are the one number worth carrying into zen: a service that is
  # "up" and logging four hundred errors is exactly what the mode is for.
  if [ "${ERR_COUNT[$key]:-0}" -gt 0 ] 2>/dev/null; then
    printf -v errs '  %b⚡%s%b' "$C_CRIT" "${ERR_COUNT[$key]}" "$RESET"
    errvis=$(( 3 + ${#ERR_COUNT[$key]} ))
  fi

  # Elided from the LEFT: a name cut to "backoffice" loses the `be-`/`fe-`
  # prefix, which in a one-row-per-component list is the half that says which
  # of the two you are looking at.
  [ ${#name} -gt "$ZEN_NAMEW" ] && name="…${name: -$(( ZEN_NAMEW - 1 ))}"

  local namec=$C_SUBTLE
  [ "$selected" = 1 ] && namec="$C_TEXT$BOLD"
  printf -v row '%*s%b %s  %b%-*s%b  %b%-*s%b  ' \
    "$ZEN_INDENT" "" "$mark" "$icon" \
    "$namec" "$ZEN_NAMEW" "$name" "$RESET" \
    "$ZWHATC" "$ZEN_WHATW" "$ZWHAT" "$RESET"
  # The indent is part of the row, so it is part of the row's width. Left out,
  # the selection band was drawn ZEN_INDENT columns too wide and ran past the
  # right edge of the block.
  ZEN_VIS=$(( ZEN_INDENT + 2 + 1 + 2 + ZEN_NAMEW + 2 + ZEN_WHATW + 2 ))

  dmax=$(( ZEN_INDENT + ZEN_BLOCKW - ZEN_VIS - errvis )); [ "$dmax" -lt 0 ] && dmax=0
  # A fragment is worse than nothing: "exi" where "exit 1 · 18:34" did not fit
  # reads as corruption, and there is no room to recognise it from a prefix.
  if [ "$dmax" -lt 6 ]; then ZDETAIL=""
  elif [ ${#ZDETAIL} -gt "$dmax" ]; then ZDETAIL="${ZDETAIL:0:$(( dmax - 1 ))}…"
  fi
  printf -v R '%b%s%b' "$ZDETAILC" "$ZDETAIL" "$RESET"
  row+="$R$errs"
  ZEN_VIS=$(( ZEN_VIS + ${#ZDETAIL} + errvis ))

  if [ "$selected" = 1 ]; then
    _band_row "$row" "$ZEN_VIS" "$(( ZEN_INDENT + ZEN_BLOCKW ))"
    row=$R; ZEN_VIS=$(( ZEN_INDENT + ZEN_BLOCKW ))
  fi
  R=$row
  return 0
}

# The one line in zen that counts what is FINE. Everywhere else the mode hides
# it on purpose; on an empty screen it is the difference between "everything is
# up" and "is this thing even running?".
_zen_all_well_line() { # → R, ZEN_VIS
  local c n_up=0 n_dep=0 dep parts
  for c in "${PITCREW_COMPS[@]}"; do
    case "${SNAP_STATE[$c]:-}" in up|external) n_up=$((n_up + 1)) ;; esac
  done
  for dep in "${PITCREW_DEPS[@]:-}"; do
    [ -n "$dep" ] && [ "${SNAP_DEP[$dep]:-down}" = up ] && n_dep=$((n_dep + 1))
  done
  printf -v parts '%s up' "$n_up"
  [ "$n_dep" -gt 0 ] && printf -v parts '%s · %s deps up' "$parts" "$n_dep"
  ZEN_VIS=${#parts}
  printf -v R '%b%s%b' "$C_FAINT" "$parts" "$RESET"
  return 0
}
