#!/usr/bin/env bash
# ext/jvm — the parsers, the rules, and the boundary with pitcrew.
#
# None of this needs a JVM. The parsers take captured jcmd output from
# ext/jvm/test/fixtures (five JDK generations and five collectors), and the
# rules take facts assigned directly — which is the entire reason probe.sh is
# the only file that forks.
#
# ── the regression these fixtures exist for ─────────────────────────────────
#
# The plugin this replaced parsed metaspace out of `GC.heap_info`. That line
# was REMOVED from the command after JDK 11. Nothing errored: metaspace simply
# read as 0, the OOM prediction that depends on it got smaller, and the check
# went on looking like it worked for two JDK releases. Every parser here
# returns -1 for "could not read" and every rule refuses to run on one.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

EXT="$PITCREW_DIR/ext/jvm"
FIX="$EXT/test/fixtures"
source "$EXT/lib/util.sh"
source "$EXT/lib/parse.sh"
source "$EXT/lib/rules.sh"

# ── parsers: the heap, across every spelling of it ──────────────────────────

test_the_heap_is_read_from_every_collector_and_jdk() {
  # Four collectors spell this four ways and G1 changed its spelling mid-life.
  # Taking the first match rather than summing reports a two-generation heap as
  # its young half, so the generational ones are the interesting cases.
  assert_eq "$(jvm_parse_heap < "$FIX/jdk8-g1-heap_info.txt")" \
    "1048576 2097152 -1 -1" "JDK 8 G1: total is the committed capacity"
  assert_eq "$(jvm_parse_heap < "$FIX/jdk26-g1-heap_info.txt")" \
    "1430 10240 524288 -1" "JDK 26 G1: total reserved / committed / used are three fields"
  assert_eq "$(jvm_parse_heap < "$FIX/jdk8-parallel-heap_info.txt")" \
    "300000 1005056 -1 -1" "Parallel: young and old are summed"
  assert_eq "$(jvm_parse_heap < "$FIX/jdk8-serial-heap_info.txt")" \
    "212345 506816 -1 -1" "Serial: new and tenured are summed"
  assert_eq "$(jvm_parse_heap < "$FIX/jdk17-zgc-heap_info.txt")" \
    "102400 1024000 -1 2097152" "ZGC: reports megabytes, and a max capacity"
  assert_eq "$(jvm_parse_heap < "$FIX/jdk17-shenandoah-heap_info.txt")" \
    "524288 1048576 -1 2097152" "Shenandoah: the value comes BEFORE the keyword"
}

test_a_percent_used_column_is_not_mistaken_for_a_size() {
  # "eden space 262144K, 38% used [0x...)" carries a `used` whose value is an
  # address. Counting it would add a gigabyte of nonsense to the heap total.
  local out
  out=$(printf '%s\n' \
    ' PSYoungGen      total 305664K, used 100000K [0x00000000eab00000)' \
    '  eden space 262144K, 38% used [0x00000000eab00000,0x00000000f0000000)' | jvm_parse_heap)
  assert_eq "$out" "100000 305664 -1 -1" "only the real figures counted"
}

test_an_unreadable_heap_is_unknown_rather_than_zero() {
  assert_eq "$(printf 'command not supported\n' | jvm_parse_heap)" "-1 -1 -1 -1" "unparseable"
  assert_eq "$(printf '' | jvm_parse_heap)" "-1 -1 -1 -1" "empty"
}

# ── parsers: metaspace, and the regression itself ───────────────────────────

test_metaspace_is_read_from_both_of_its_homes() {
  # Up to JDK 11 it was a line inside GC.heap_info; from 17 it is only in
  # VM.metaspace. Reading one and not the other is the original bug.
  assert_eq "$(jvm_parse_metaspace < "$FIX/jdk8-g1-heap_info.txt")" \
    "45678 46000 1114112 5200" "JDK 8: inside GC.heap_info"
  assert_eq "$(jvm_parse_metaspace < "$FIX/jdk26-metaspace.txt")" \
    "87 320 1114112 128" "JDK 26: its own command"
}

test_a_modern_heap_info_reports_metaspace_as_unknown_not_zero() {
  # THE regression, pinned. A JDK 17+ GC.heap_info has no Metaspace line at
  # all. The honest answer is -1; the answer that hid this for two releases
  # was 0, because 0 flows through the cap arithmetic looking like a measurement.
  local out; out=$(jvm_parse_metaspace < "$FIX/jdk26-g1-heap_info.txt")
  assert_eq "$out" "-1 -1 -1 -1" "absent is unknown"
  assert_not_match "$out" '(^| )0( |$)' "and specifically is NOT zero"
}

test_class_space_is_not_counted_as_metaspace() {
  # Class space reports its own `used`/`committed` and is a SUBSET of
  # metaspace, so adding it would count part of it twice.
  local out; out=$(jvm_parse_metaspace < "$FIX/jdk8-g1-heap_info.txt")
  assert_match "$out" '^45678 46000 ' "metaspace figures are its own"
}

# ── parsers: the code cache ─────────────────────────────────────────────────

test_a_full_code_cache_is_visible() {
  # full_count past zero means the JIT stopped compiling, permanently. It is
  # the most consequential number here and nothing else surfaces it.
  assert_eq "$(jvm_parse_codecache < "$FIX/jdk17-codecache-full.txt")" \
    "245764 244900 3" "size, used, and the number of times it filled"
}

test_the_aggregate_code_cache_line_wins_over_the_segments() {
  # With SegmentedCodeCache there are per-heap lines too; summing them and the
  # aggregate would double the total.
  local out; out=$(jvm_parse_codecache < "$FIX/jdk26-codecache.txt")
  assert_eq "$out" "245764 1214 0" "the CodeCache: line only"
}

test_a_jdk_without_full_count_says_unknown() {
  # JDK 8 does not print it. "It has never filled" and "we cannot tell" are
  # different claims and must not render as the same one.
  assert_eq "$(jvm_parse_codecache < "$FIX/jdk8-codecache.txt")" \
    "245760 15000 -1" "absent full_count is -1, not 0"
}

# ── parsers: flags, and the number too big for a shell ──────────────────────

test_an_unlimited_flag_is_clamped_before_it_reaches_arithmetic() {
  # MaxMetaspaceSize defaults to 18446744073709551615, which is wider than a
  # signed 64-bit integer. The shell does not reject it — it TRUNCATES it and
  # carries on, so an unlimited metaspace would read as a ceiling of about 1.6
  # exabytes that nothing ever approaches, and the check would never fire.
  local v; v=$(jvm_parse_flags_all < "$FIX/jdk26-flags-all.txt" | jvm_flag MaxMetaspaceSize)
  assert_eq "$v" "-1" "clamped to unknown in awk"
}

test_flags_are_normalised_from_both_formats() {
  local all; all=$(jvm_parse_flags_all < "$FIX/jdk26-flags-all.txt")
  assert_eq "$(printf '%s\n' "$all" | jvm_flag MaxHeapSize)" "536870912" "a size"
  assert_eq "$(printf '%s\n' "$all" | jvm_flag UseContainerSupport)" "1" "true becomes 1"
  assert_eq "$(printf '%s\n' "$all" | jvm_flag ThreadStackSize)" "1024" "already in KB"
  assert_eq "$(printf '%s\n' "$all" | jvm_flag MaxRAMPercentage)" "25.000000" "a double survives"
  # The short form is the -XX:Name=value spelling.
  local short; short=$(jvm_parse_flags < "$FIX/jdk26-flags.txt")
  assert_eq "$(printf '%s\n' "$short" | jvm_flag MaxHeapSize)" "536870912" "short form too"
  assert_eq "$(printf '%s\n' "$short" | jvm_flag SegmentedCodeCache)" "1" "+Flag becomes 1"
}

test_an_unset_flag_is_absent_rather_than_zero() {
  assert_empty "$(jvm_parse_flags_all < "$FIX/jdk26-flags-all.txt" | jvm_flag NoSuchFlag)" \
    "absent means absent"
}

# ── parsers: NMT, /proc, cgroup ─────────────────────────────────────────────

test_nmt_categories_are_looked_up_by_their_spaced_names() {
  # "Java Heap" and "Shared class space" contain spaces, so the name cannot be
  # a field — it is everything between the leading dash and the bracket.
  local cats; cats=$(jvm_parse_nmt < "$FIX/jdk26-nmt.txt")
  assert_eq "$(printf '%s\n' "$cats" | jvm_nmt_committed "Java Heap")" "10240" "a two-word category"
  assert_eq "$(printf '%s\n' "$cats" | jvm_nmt_committed "Total")" "110208" "the total"
  assert_eq "$(printf '%s\n' "$cats" | jvm_nmt_committed "GC")" "74675" "GC structures"
  assert_eq "$(printf '%s\n' "$cats" | jvm_nmt_committed "Nonexistent")" "-1" "a category that is not there"
}

test_proc_status_yields_rss_swap_and_threads() {
  assert_match "$(jvm_parse_proc_status < "$FIX/linux-proc-status.txt")" \
    '^[0-9]+ [0-9]+ [0-9]+$' "three numbers"
}

test_an_unlimited_cgroup_is_not_a_cap_of_eight_exabytes() {
  # v2 writes the literal "max"; v1 writes PAGE_COUNTER_MAX. Both mean no limit,
  # and a huge number read as a real cap makes every JVM look comfortable.
  assert_eq "$(printf 'max\n'                  | jvm_parse_cgroup_max)" "-1" "v2 unlimited"
  assert_eq "$(printf '9223372036854771712\n'  | jvm_parse_cgroup_max)" "-1" "v1 unlimited"
  assert_eq "$(printf '2147483648\n'           | jvm_parse_cgroup_max)" "2147483648" "a real 2G limit"
  assert_eq "$(printf ''                       | jvm_parse_cgroup_max)" "-1" "empty file"
}

# ── the rules ───────────────────────────────────────────────────────────────

_facts() { # a healthy 1G-heap service under a 4G cap; tests override one thing
  JVMF_LABEL=be-test; JVMF_PID=1234
  JVMF_CAP_B=$(( 4096 * 1024 * 1024 )); JVMF_CAP_SOURCE=pitcrew
  JVMF_HEAP_MAX_K=$(( 1024 * 1024 )); JVMF_HEAP_COMMIT_K=$(( 300 * 1024 )); JVMF_HEAP_USED_K=$(( 120 * 1024 ))
  JVMF_META_USED_K=$(( 85 * 1024 )); JVMF_META_COMMIT_K=$(( 90 * 1024 )); JVMF_META_MAX_K=-1
  JVMF_CC_SIZE_K=$(( 240 * 1024 )); JVMF_CC_USED_K=$(( 30 * 1024 )); JVMF_CC_FULL=0
  JVMF_RSS_K=$(( 520 * 1024 )); JVMF_THREADS=40; JVMF_STACK_K=1024
  JVMF_SWAP_K=0; JVMF_CONTAINER=1; JVMF_UPTIME=3600; JVMF_ATTACHED=1
  JVMF_NMT=0; JVMF_NMT_TOTAL_K=-1; JVMF_NMT_HEAP_K=-1; JVMF_NMT_THREAD_K=-1
  JVMF_NMT_CODE_K=-1; JVMF_NMT_CLASS_K=-1; JVMF_NMT_GC_K=-1
  jvm_finding_reset
}

_ids() { # the finding ids raised, space separated
  local i out=""
  for i in "${!JVMR_ID[@]}"; do out+="${out:+ }${JVMR_ID[i]}"; done
  printf '%s' "$out"
}

_detail_of() { # $1 id -> its detail line
  local i
  for i in "${!JVMR_ID[@]}"; do
    [ "${JVMR_ID[i]}" = "$1" ] && { printf '%s' "${JVMR_DETAIL[i]}"; return 0; }
  done
  return 0
}

test_a_healthy_jvm_produces_no_findings() {
  # The bar for saying anything at all: every check competes for the one line
  # someone will actually read.
  _facts; jvm_rules
  assert_empty "$(_ids)" "nothing to say about a healthy service"
}

test_the_cap_check_fires_when_xmx_plus_non_heap_exceeds_the_cap() {
  _facts
  JVMF_CAP_B=$(( 1024 * 1024 * 1024 ))     # 1G cap, 1G heap, plus non-heap
  jvm_rules
  assert_match "$(_ids)" 'jvm-cap' "raised"
  assert_match "$(_detail_of jvm-cap)" 'kernel kills it first' "says what actually happens"
}

test_the_cap_check_refuses_to_guess_when_the_heap_max_is_unknown() {
  # Half the arithmetic missing must mean silence, not a smaller number.
  _facts
  JVMF_CAP_B=$(( 128 * 1024 * 1024 )); JVMF_HEAP_MAX_K=-1
  jvm_rules
  assert_not_match "$(_ids)" 'jvm-cap' "no finding without a measured -Xmx"
}

test_an_unmeasured_non_heap_is_described_as_a_floor() {
  # With NMT off, GC structures and direct buffers cannot be read, so the need
  # figure is a LOWER bound. When a lower bound already exceeds the cap the
  # conclusion is certain — but the wording has to say which it is.
  _facts
  JVMF_CAP_B=$(( 1024 * 1024 * 1024 ))
  jvm_rules
  assert_match "$(_detail_of jvm-cap)" 'at least' "hedged where the evidence is a floor"

  _facts
  JVMF_CAP_B=$(( 1024 * 1024 * 1024 ))
  JVMF_NMT=1; JVMF_NMT_TOTAL_K=$(( 900 * 1024 )); JVMF_NMT_HEAP_K=$(( 300 * 1024 ))
  jvm_rules
  assert_match "$(_detail_of jvm-cap)" 'measured non-heap' "stated flatly where it was measured"
}

test_the_two_figures_in_the_cap_sentence_never_round_to_the_same_string() {
  # 1571M and 1536M both render "1.5G", and "needs 1.5G, the cap is 1.5G" is a
  # critical finding whose own evidence reads as a non-finding.
  _facts
  JVMF_HEAP_MAX_K=$(( 1024 * 1024 )); JVMF_CAP_B=$(( 1536 * 1024 * 1024 ))
  # 1048576K heap + 184320K metaspace + 244736K code cache + a 131072K floor
  # is 1608704K = 1571M, against a cap of 1572864K = 1536M. Both render "1.5G".
  JVMF_META_COMMIT_K=$(( 180 * 1024 )); JVMF_CC_USED_K=$(( 239 * 1024 ))
  jvm_rules
  local d; d=$(_detail_of jvm-cap)
  assert_match "$d" 'needs 1571M or more, the cap is 1536M' "dropped to a unit that distinguishes them"
}

test_a_filled_code_cache_is_critical_and_says_the_jit_stopped() {
  _facts; JVMF_CC_FULL=2
  jvm_rules
  assert_match "$(_ids)" 'jvm-codecache' "raised"
  assert_match "$(_detail_of jvm-codecache)" 'stopped compiling' "names the actual consequence"
}

test_an_unknown_full_count_raises_nothing() {
  # JDK 8 does not report it. Absent must not read as "it has never filled".
  _facts; JVMF_CC_FULL=-1; JVMF_CC_USED_K=$(( 30 * 1024 ))
  jvm_rules
  assert_not_match "$(_ids)" 'jvm-codecache' "silent on what it cannot see"
}

test_metaspace_is_only_judged_against_a_ceiling_that_exists() {
  # Unbounded is the default. A large unbounded metaspace is not news.
  _facts; JVMF_META_USED_K=$(( 4096 * 1024 )); JVMF_META_MAX_K=-1
  jvm_rules
  assert_not_match "$(_ids)" 'jvm-metaspace' "no ceiling, no finding"

  _facts; JVMF_META_MAX_K=$(( 192 * 1024 )); JVMF_META_USED_K=$(( 185 * 1024 ))
  jvm_rules
  assert_match "$(_ids)" 'jvm-metaspace' "against a ceiling someone set, it fires"
}

test_committed_above_resident_is_never_reported_as_unaccounted() {
  # A JVM routinely commits more than it has touched: NMT said 110M committed
  # while /proc said 41M resident. That is normal, and reporting it as missing
  # memory would make the tool look broken on every healthy service.
  _facts
  JVMF_NMT=1; JVMF_NMT_TOTAL_K=$(( 2048 * 1024 )); JVMF_NMT_HEAP_K=$(( 300 * 1024 ))
  JVMF_RSS_K=$(( 200 * 1024 ))
  jvm_rules
  assert_not_match "$(_ids)" 'jvm-unaccounted' "the negative direction is silent"
  assert_eq "$JVMA_UNACCOUNTED_KNOWN" "1" "but it WAS computed"
  [ "${JVMA_UNACCOUNTED_K}" -lt 0 ] || _t_bad "expected a negative difference, got $JVMA_UNACCOUNTED_K"
}

test_rss_far_above_the_accounting_is_reported() {
  _facts; JVMF_RSS_K=$(( 3000 * 1024 ))
  jvm_rules
  assert_match "$(_ids)" 'jvm-unaccounted' "the positive direction is a finding"
}

test_a_jvm_blind_to_its_own_cgroup_is_reported() {
  # It sizes its heap from the whole machine: on a 64G box with a 2G limit that
  # is a 16G default heap, killed the first time it is used.
  _facts; JVMF_CONTAINER=0
  jvm_rules
  assert_match "$(_ids)" 'jvm-container' "raised"

  _facts; JVMF_CONTAINER=0; JVMF_CAP_B=-1
  jvm_rules
  assert_not_match "$(_ids)" 'jvm-container' "with no cap there is nothing to be blind to"
}

test_findings_carry_the_component_as_their_scope() {
  # pitcrew routes a finding to a row by its scope; an empty one goes to the
  # machine-wide list and the row shows nothing.
  _facts; JVMF_CAP_B=$(( 1024 * 1024 * 1024 ))
  jvm_rules
  local i seen=0
  for i in "${!JVMR_ID[@]}"; do
    [ "${JVMR_SCOPE[i]}" = "be-test" ] && seen=1
  done
  assert_eq "$seen" "1" "scoped to the component"
}

test_a_fix_command_is_one_pitcrew_understands() {
  # The desktop app parses this against a whitelist and runs it as argv. A fix
  # that is not a real command must be empty rather than prose.
  _facts; JVMF_CAP_B=$(( 1024 * 1024 * 1024 )); JVMF_CAP_SOURCE=pitcrew
  jvm_rules
  local i fix=""
  for i in "${!JVMR_ID[@]}"; do
    [ "${JVMR_ID[i]}" = "jvm-cap" ] && fix=${JVMR_FIX[i]}
  done
  assert_match "$fix" '^pitcrew limit be-test ' "a real pitcrew invocation"

  # Where the cap did not come from pitcrew there is no pitcrew command to give.
  _facts; JVMF_CAP_B=$(( 1024 * 1024 * 1024 )); JVMF_CAP_SOURCE=cgroup
  jvm_rules
  fix=""
  for i in "${!JVMR_ID[@]}"; do
    [ "${JVMR_ID[i]}" = "jvm-cap" ] && fix=${JVMR_FIX[i]}
  done
  assert_empty "$fix" "no invented command for a cgroup cap"
}

# ── formatting ──────────────────────────────────────────────────────────────

test_unknown_renders_as_a_question_mark_not_a_zero() {
  jvm_human -1; assert_eq "$JVM_H" "?" "unknown is visibly unknown"
  jvm_human 0;  assert_eq "$JVM_H" "0K" "measured zero is a zero"
}

test_a_negative_difference_renders_with_its_sign() {
  # Only the accounted-versus-resident figure can be legitimately negative.
  jvm_human_signed -68924; assert_eq "$JVM_H" "-67M" "signed"
  jvm_human_signed 68924;  assert_eq "$JVM_H" "67M" "and positive is unchanged"
}

test_two_compared_sizes_are_forced_apart_only_when_they_collide() {
  jvm_human2 1608704 1572864          # 1571M vs 1536M — both "1.5G"
  assert_eq "$JVM_H1" "1571M" "dropped to MB"
  assert_eq "$JVM_H2" "1536M" "both sides"
  jvm_human2 $(( 1024 * 1024 )) $(( 2048 * 1024 ))
  assert_eq "$JVM_H1" "1.0G" "left alone when they already differ"
  jvm_human2 1048576 1048576
  assert_eq "$JVM_H1" "$JVM_H2" "genuinely equal values stay equal"
}

run_tests
