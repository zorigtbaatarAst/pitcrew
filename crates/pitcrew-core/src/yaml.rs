//! The YAML front end: a deliberately small subset, and loud about the rest.
//!
//! This is a hand-written parser, not a YAML library, for the same reason
//! `lib/18-yaml.sh` was: what pitcrew accepts is a narrow subset, and most of
//! the value here is in the **refusals**. A general parser accepts
//! `port:8080` as the plain scalar `"port:8080"` — which is a typo that then
//! renders as a component with no port and no complaint. Refusing it with a
//! line number is the feature.
//!
//! Supported: block mappings nested by space indentation · block and flow
//! sequences of scalars · flow mappings of scalars, one line per component ·
//! single- and double-quoted scalars · `|` and `>` block scalars with `-`/`+`
//! chomping · `#` comments · `include:`.
//!
//! Refused, each with a file and line: tabs for indentation · anchors and
//! aliases · tags · merge keys · sequences of mappings · nested flow
//! collections · a missing space after `:` · an unterminated quote.
//!
//! The output is the document flattened into dotted paths **in document
//! order** — `apps.storefront.be.cmd` — which is what makes app ordering fall
//! out of the file rather than needing to be tracked separately. Mapping those
//! paths onto the config model is [`crate::load`]'s job; nothing here knows
//! what a component is.

use std::fmt;

/// One flattened `path: value` pair, with the line it came from so a later
/// complaint about it can still be located.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    pub value: String,
    pub line: usize,
}

/// A refusal. Always carries a line, because "your config is wrong" without
/// one is a worse message than no message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    pub line: usize,
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for ParseError {}

fn err<T>(line: usize, message: impl Into<String>) -> Result<T, ParseError> {
    Err(ParseError {
        line,
        message: message.into(),
    })
}

/// One open block. `seq` counts list items so `watch.0`, `watch.1` fall out
/// without a second pass.
struct Frame {
    indent: usize,
    key: String,
    seq: usize,
}

/// Flatten a document into dotted paths, in order.
pub fn parse(text: &str) -> Result<Vec<Entry>, ParseError> {
    let mut out = Vec::new();
    let mut stack: Vec<Frame> = Vec::new();
    let mut lines = text.lines().enumerate().peekable();

    while let Some((idx, raw)) = lines.next() {
        let lineno = idx + 1;
        let indent = raw.len() - raw.trim_start().len();

        // Tabs are checked against the INDENT only. A tab inside a value is a
        // tab inside a value; a tab in the indent is a file that means
        // something different in every editor it is opened in.
        if raw[..indent].contains('\t') {
            return err(lineno, "tabs cannot be used to indent YAML — use spaces");
        }

        let stripped = raw.trim();
        if stripped.is_empty() || stripped.starts_with('#') {
            continue;
        }
        if stripped.starts_with("<<:") {
            return err(lineno, "merge keys (<<:) are not supported");
        }

        // ── a list item ──────────────────────────────────────────────────
        if stripped == "-" || stripped.starts_with("- ") {
            // Strictly greater, so a list written at its key's own indent —
            // which is legal YAML and common — still belongs to that key.
            while stack.last().is_some_and(|f| f.indent > indent) {
                stack.pop();
            }
            let Some(frame) = stack.last_mut() else {
                return err(lineno, "list item outside of any key");
            };
            let item = stripped[1..].trim();
            // `- key: value` is a sequence of mappings. Every list in a
            // pitcrew config is a list of plain values, and silently reading
            // the first key of each would be worse than refusing.
            if is_key_line(item) {
                return err(
                    lineno,
                    "a list of mappings is not supported here — every list in a \
                     pitcrew config is a list of plain values",
                );
            }
            let index = frame.seq;
            frame.seq += 1;
            let path = format!("{}.{index}", path_of(&stack));
            let value = scalar(item, lineno)?;
            out.push(Entry {
                path,
                value,
                line: lineno,
            });
            continue;
        }

        // ── a key ────────────────────────────────────────────────────────
        while stack.last().is_some_and(|f| f.indent >= indent) {
            stack.pop();
        }
        let (key, rest) = split_key(stripped, lineno)?;
        let parent = path_of(&stack);

        // App names become component names, log file names and unit names, and
        // this parser splits its own paths on dots. Both reasons point the same
        // way, so it is said once, here, rather than misparsed quietly: an app
        // called `my.app` would otherwise read as an app `my` with a role `app`.
        if parent == "apps" && key.contains(['.', '/', ' ']) {
            return err(
                lineno,
                format!("app name '{key}' cannot contain '.', '/' or a space"),
            );
        }

        let path = if parent.is_empty() {
            key.clone()
        } else {
            format!("{parent}.{key}")
        };

        // A bare `key:` opens a block…
        if rest.is_empty() {
            stack.push(Frame {
                indent,
                key,
                seq: 0,
            });
            continue;
        }
        // …unless it opens a block scalar, which is a value spelled over
        // several lines rather than a nested mapping.
        if let Some(spec) = block_scalar_spec(&rest) {
            let mut body = Vec::new();
            while let Some(&(next_idx, next_raw)) = lines.peek() {
                let next_indent = next_raw.len() - next_raw.trim_start().len();
                if next_raw.trim().is_empty() {
                    body.push(String::new());
                    lines.next();
                    continue;
                }
                if next_indent <= indent {
                    break;
                }
                let _ = next_idx;
                body.push(next_raw.trim_start().to_string());
                lines.next();
            }
            out.push(Entry {
                path,
                value: fold_block(&body, spec),
                line: lineno,
            });
            continue;
        }

        if let Some(items) = flow_seq(&rest, lineno)? {
            for (i, item) in items.into_iter().enumerate() {
                out.push(Entry {
                    path: format!("{path}.{i}"),
                    value: item,
                    line: lineno,
                });
            }
            continue;
        }
        if let Some(pairs) = flow_map(&rest, lineno)? {
            for (k, v) in pairs {
                out.push(Entry {
                    path: format!("{path}.{k}"),
                    value: v,
                    line: lineno,
                });
            }
            continue;
        }

        out.push(Entry {
            path,
            value: scalar(&rest, lineno)?,
            line: lineno,
        });
    }
    Ok(out)
}

fn path_of(stack: &[Frame]) -> String {
    stack
        .iter()
        .map(|f| f.key.as_str())
        .collect::<Vec<_>>()
        .join(".")
}

/// Does this look like `key: value` rather than a plain scalar? Used only to
/// spot a mapping where a list item was expected.
fn is_key_line(s: &str) -> bool {
    match s.find(':') {
        Some(i) => s[i + 1..].starts_with(' ') || i + 1 == s.len(),
        None => false,
    }
}

/// Split `key: value` into its two halves, refusing the shapes that are almost
/// always a typo rather than an intention.
fn split_key(s: &str, line: usize) -> Result<(String, String), ParseError> {
    // A quoted key, for the rare name that needs one.
    if let Some(q) = s.chars().next().filter(|c| *c == '"' || *c == '\'') {
        let body = &s[1..];
        let Some(end) = body.find(q) else {
            return err(line, "unterminated quoted key");
        };
        let key = body[..end].to_string();
        let rest = body[end + 1..].trim_start();
        let Some(rest) = rest.strip_prefix(':') else {
            return err(line, "expected ':' after a quoted key");
        };
        return Ok((key, rest.trim().to_string()));
    }

    match s.find(':') {
        // `key:` at end of line — opens a block.
        Some(i) if i + 1 == s.len() => Ok((s[..i].trim().to_string(), String::new())),
        Some(i) if s[i + 1..].starts_with(' ') => {
            Ok((s[..i].trim().to_string(), s[i + 1..].trim().to_string()))
        }
        // The whole reason this is not a general YAML parser. `port:8080` is a
        // valid plain scalar to YAML and a typo to everyone else.
        Some(i) => err(
            line,
            format!(
                "a key needs a space after its colon — write '{}: {}', not '{}'",
                &s[..i],
                &s[i + 1..],
                s
            ),
        ),
        None => err(line, format!("expected 'key: value' — got: {s}")),
    }
}

/// `|`, `>`, with optional `-`/`+` chomping. Returns (folded, chomp).
#[derive(Clone, Copy, PartialEq, Eq)]
struct BlockSpec {
    folded: bool,
    keep: bool,
    strip: bool,
}

fn block_scalar_spec(rest: &str) -> Option<BlockSpec> {
    let mut chars = rest.chars();
    let folded = match chars.next()? {
        '|' => false,
        '>' => true,
        _ => return None,
    };
    let tail = chars.as_str().trim();
    // Anything other than a chomping indicator after `|` means this is a plain
    // scalar that merely starts with a pipe.
    match tail {
        "" => Some(BlockSpec {
            folded,
            keep: false,
            strip: false,
        }),
        "-" => Some(BlockSpec {
            folded,
            keep: false,
            strip: true,
        }),
        "+" => Some(BlockSpec {
            folded,
            keep: true,
            strip: false,
        }),
        _ => None,
    }
}

fn fold_block(body: &[String], spec: BlockSpec) -> String {
    let joined = if spec.folded {
        // A folded block is one line: that is the entire point of `>` for a
        // start command written across three lines for readability.
        body.iter()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        body.join("\n")
    };
    if spec.strip {
        joined.trim_end_matches('\n').to_string()
    } else if spec.keep {
        joined
    } else {
        // Clip: at most one trailing newline, which for a single-value config
        // is none.
        joined.trim_end_matches('\n').to_string()
    }
}

/// `[a, b, c]` → the items, or `None` when this is not a flow sequence.
fn flow_seq(rest: &str, line: usize) -> Result<Option<Vec<String>>, ParseError> {
    let Some(body) = rest.strip_prefix('[') else {
        return Ok(None);
    };
    let Some(body) = body
        .strip_suffix(']')
        .or_else(|| strip_comment_after(body, ']'))
    else {
        return err(line, "unterminated flow sequence — no closing ]");
    };
    if body.contains('[') || body.contains(']') || body.contains('{') {
        return err(line, "nested flow collections are not supported");
    }
    let mut out = Vec::new();
    for item in split_commas(body, line)? {
        let item = item.trim();
        if item.is_empty() {
            continue;
        }
        out.push(scalar(item, line)?);
    }
    Ok(Some(out))
}

/// `{a: b, c: d}` → the pairs, or `None` when this is not a flow mapping.
fn flow_map(rest: &str, line: usize) -> Result<Option<Vec<(String, String)>>, ParseError> {
    let Some(body) = rest.strip_prefix('{') else {
        return Ok(None);
    };
    let Some(body) = body
        .strip_suffix('}')
        .or_else(|| strip_comment_after(body, '}'))
    else {
        return err(line, "unterminated flow mapping — no closing }");
    };
    if body.contains('{') || body.contains('}') || body.contains('[') || body.contains(']') {
        return err(line, "nested flow collections are not supported");
    }
    let mut out = Vec::new();
    for item in split_commas(body, line)? {
        let item = item.trim();
        if item.is_empty() {
            continue;
        }
        let Some(i) = item.find(':') else {
            return err(
                line,
                format!(
                    "'{item}' is not a 'key: value' pair — a comma inside a value needs quoting"
                ),
            );
        };
        let key = item[..i].trim();
        if key.is_empty() {
            return err(line, "a flow mapping entry has no key");
        }
        out.push((key.to_string(), scalar(item[i + 1..].trim(), line)?));
    }
    Ok(Some(out))
}

/// Trailing `]`/`}` followed by a comment.
fn strip_comment_after(body: &str, close: char) -> Option<&str> {
    let i = body.rfind(close)?;
    let after = body[i + 1..].trim();
    (after.is_empty() || after.starts_with('#')).then(|| &body[..i])
}

/// Split on commas that are not inside quotes.
fn split_commas(body: &str, line: usize) -> Result<Vec<String>, ParseError> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    for c in body.chars() {
        match (quote, c) {
            (Some(q), _) if c == q => {
                quote = None;
                cur.push(c);
            }
            (Some(_), _) => cur.push(c),
            (None, '"') | (None, '\'') => {
                quote = Some(c);
                cur.push(c);
            }
            (None, ',') => out.push(std::mem::take(&mut cur)),
            (None, _) => cur.push(c),
        }
    }
    if quote.is_some() {
        return err(line, "unterminated quote inside a flow mapping");
    }
    out.push(cur);
    Ok(out)
}

/// One scalar value: quoted, or plain with an inline comment removed.
fn scalar(s: &str, line: usize) -> Result<String, ParseError> {
    let s = s.trim();
    match s.chars().next() {
        None => Ok(String::new()),
        // A value that begins with an anchor, alias or tag is YAML pitcrew does
        // not read. Half-reading it would produce a start command that is not
        // the one in the file.
        Some('&') | Some('*') => err(
            line,
            "anchors and aliases are not supported — write the value out",
        ),
        Some('!') => err(line, "tags are not supported"),
        Some(q @ ('"' | '\'')) => {
            let body = &s[1..];
            let Some(end) = find_close(body, q) else {
                return err(line, "unterminated quoted value");
            };
            let after = body[end + 1..].trim();
            if !after.is_empty() && !after.starts_with('#') {
                return err(
                    line,
                    format!("unexpected text after a quoted value: {after}"),
                );
            }
            Ok(unescape(&body[..end], q))
        }
        // A plain scalar ends at a ` #`. Not at a bare `#`, because a start
        // command may legitimately contain one and requiring a space before a
        // comment is what YAML itself says.
        _ => Ok(match s.find(" #") {
            Some(i) => s[..i].trim_end().to_string(),
            None => s.to_string(),
        }),
    }
}

fn find_close(body: &str, q: char) -> Option<usize> {
    let bytes: Vec<char> = body.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == q {
            // '' inside a single-quoted scalar is an escaped quote.
            if q == '\'' && bytes.get(i + 1) == Some(&'\'') {
                i += 2;
                continue;
            }
            return Some(body.char_indices().nth(i).map(|(b, _)| b).unwrap_or(i));
        }
        if q == '"' && bytes[i] == '\\' {
            i += 2;
            continue;
        }
        i += 1;
    }
    None
}

fn unescape(s: &str, q: char) -> String {
    if q == '\'' {
        return s.replace("''", "'");
    }
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some('"') => out.push('"'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `path=value` lines, for compact assertions.
    fn flat(text: &str) -> Vec<String> {
        parse(text)
            .expect("parse")
            .into_iter()
            .map(|e| format!("{}={}", e.path, e.value))
            .collect()
    }

    fn refused(text: &str) -> String {
        parse(text).expect_err("should have been refused").message
    }

    // ── what it reads ───────────────────────────────────────────────────

    /// Document order is the contract: it is where app ordering comes from, so
    /// a parser that sorted its output would silently reshuffle the dashboard.
    #[test]
    fn nesting_flattens_to_dotted_paths_in_document_order() {
        let out = flat("apps:\n  b:\n    be:\n      cmd: x\n  a:\n    fe:\n      cmd: y\n");
        assert_eq!(out, ["apps.b.be.cmd=x", "apps.a.fe.cmd=y"]);
    }

    #[test]
    fn lists_work_in_both_block_and_flow_style() {
        assert_eq!(flat("deps: [a, b]\n"), ["deps.0=a", "deps.1=b"]);
        assert_eq!(flat("deps:\n  - a\n  - b\n"), ["deps.0=a", "deps.1=b"]);
        // A list at its key's own indent is legal YAML and common in the wild.
        assert_eq!(flat("deps:\n- a\n- b\n"), ["deps.0=a", "deps.1=b"]);
    }

    /// A flow mapping is one line for one component — what makes a group with
    /// four roles four lines instead of twenty.
    #[test]
    fn a_flow_mapping_is_one_line_for_one_component() {
        let out = flat("apps:\n  a:\n    be: {cmd: \"true\", port: 8080}\n");
        assert_eq!(out, ["apps.a.be.cmd=true", "apps.a.be.port=8080"]);
    }

    /// `key:` followed by several spaces used to leave the whitespace on the
    /// front of the value, so an aligned flow mapping did not look like one and
    /// was read as an ordinary scalar that quietly did nothing.
    #[test]
    fn aligning_values_does_not_change_what_they_mean() {
        let out = flat("apps:\n  a:\n    be:      { cmd: \"true\", port: 1 }\ndeps:      [x, y]\n");
        assert_eq!(
            out,
            [
                "apps.a.be.cmd=true",
                "apps.a.be.port=1",
                "deps.0=x",
                "deps.1=y"
            ]
        );
    }

    /// Commas separate flow-mapping pairs, so a quoted one has to survive
    /// intact — otherwise a command is silently cut in half.
    #[test]
    fn a_quoted_comma_survives_a_flow_mapping() {
        let out = flat("apps:\n  a:\n    be: { cmd: \"npm run build, npm start\" }\n");
        assert_eq!(out, ["apps.a.be.cmd=npm run build, npm start"]);
    }

    /// `>-` folds newlines into spaces: a long start command written over three
    /// lines for readability is still one command.
    #[test]
    fn a_folded_block_scalar_becomes_one_line() {
        let out = flat("cmd: >-\n  true\n  --folded\n");
        assert_eq!(out, ["cmd=true --folded"]);
    }

    /// `|` keeps them, because that is the difference between the two.
    #[test]
    fn a_literal_block_scalar_keeps_its_newlines() {
        let out = flat("cmd: |\n  one\n  two\n");
        assert_eq!(out, ["cmd=one\ntwo"]);
    }

    /// `db: "echo db"   # a comment` used to become the whole tail — a
    /// different command than the one written.
    #[test]
    fn an_inline_comment_after_a_quoted_value_is_not_part_of_it() {
        assert_eq!(
            flat("shells:\n  db: \"echo db\"   # a comment\n"),
            ["shells.db=echo db"]
        );
    }

    /// A bare `#` is not a comment. A start command may legitimately contain
    /// one, and YAML itself requires the space.
    #[test]
    fn a_hash_without_a_space_stays_in_the_value() {
        assert_eq!(
            flat("cmd: curl http://x/#frag\n"),
            ["cmd=curl http://x/#frag"]
        );
        assert_eq!(flat("cmd: run # trailing\n"), ["cmd=run"]);
    }

    #[test]
    fn quotes_are_unescaped() {
        assert_eq!(flat("a: 'it''s'\n"), ["a=it's"]);
        assert_eq!(flat(r#"a: "say \"hi\"""#), [r#"a=say "hi""#]);
    }

    /// Keys can be quoted, which is how a doctor label with a colon in it gets
    /// written at all.
    #[test]
    fn a_quoted_key_is_read_as_one_key() {
        assert_eq!(
            flat("doctor:\n  \"bundler: present\": command -v bundle\n"),
            ["doctor.bundler: present=command -v bundle"]
        );
    }

    // ── what it refuses, and why each refusal exists ────────────────────

    /// A tab in the indent is a file that means something different in every
    /// editor it is opened in.
    #[test]
    fn tabs_for_indentation_are_rejected() {
        assert!(refused("apps:\n\ta:\n\t  be:\n\t    cmd: x\n").contains("tabs cannot be used"));
    }

    /// The whole reason this is not a general YAML parser: `name:fixture` is a
    /// valid plain scalar to YAML and a typo to everyone else.
    #[test]
    fn a_missing_space_after_the_colon_is_rejected() {
        let msg = refused("name:fixture\n");
        assert!(msg.contains("needs a space after its colon"), "{msg}");
        // The message shows the fix, not just the complaint.
        assert!(msg.contains("'name: fixture'"), "{msg}");
    }

    #[test]
    fn anchors_aliases_and_tags_are_rejected() {
        assert!(refused("base: &b \"true\"\n").contains("anchors and aliases"));
        assert!(refused("name: *b\n").contains("anchors and aliases"));
        assert!(refused("name: !!str x\n").contains("tags are not supported"));
    }

    #[test]
    fn merge_keys_are_rejected() {
        assert!(refused("a:\n  <<: *base\n").contains("merge keys"));
    }

    /// Every list in a pitcrew config is a list of plain values. Silently
    /// reading the first key of each mapping would be worse than refusing.
    #[test]
    fn a_list_of_mappings_is_rejected() {
        assert!(refused("apps:\n  - name: a\n    cmd: \"true\"\n").contains("list of mappings"));
    }

    #[test]
    fn nested_flow_collections_are_rejected() {
        assert!(
            refused("apps:\n  a:\n    be: { cmd: \"true\", watch: [x, y] }\n")
                .contains("nested flow collections")
        );
    }

    /// An unquoted comma would truncate a command mid-way. That is an error
    /// rather than a silent cut.
    #[test]
    fn an_unquoted_comma_in_a_flow_mapping_is_rejected() {
        let msg = refused("apps:\n  a:\n    be: { cmd: npm run build, npm start }\n");
        assert!(
            msg.contains("a comma inside a value needs quoting"),
            "{msg}"
        );
    }

    #[test]
    fn unterminated_quotes_are_rejected() {
        assert!(refused("name: \"unclosed\n").contains("unterminated quoted value"));
        assert!(refused("\"unclosed: x\n").contains("unterminated quoted key"));
    }

    /// `my.app` would read as an app `my` with a role `app` — a misparse, not
    /// a name. The path encoding is the reason, and the component id, log file
    /// name and unit name all agree with it.
    #[test]
    fn an_app_name_with_a_dot_slash_or_space_is_rejected() {
        for bad in ["my.app", "my/app", "my app"] {
            let text = format!("apps:\n  {bad}:\n    be:\n      cmd: x\n");
            let msg = refused(&text);
            assert!(msg.contains("cannot contain"), "{bad}: {msg}");
        }
        // A dash is fine and common.
        assert!(parse("apps:\n  my-app:\n    be:\n      cmd: x\n").is_ok());
    }

    #[test]
    fn a_list_item_outside_any_key_is_rejected() {
        assert!(refused("- a\n").contains("outside of any key"));
    }

    /// Every refusal carries a line number. "Your config is wrong" without one
    /// is a worse message than no message.
    #[test]
    fn every_refusal_names_its_line() {
        let e = parse("name: ok\n\n# comment\nbad:value\n").expect_err("refused");
        assert_eq!(e.line, 4);
        assert!(e.to_string().starts_with("line 4:"));
    }

    /// Blank lines and comments must not shift the line count, or every
    /// reported location in a commented config is wrong.
    #[test]
    fn comments_and_blanks_do_not_shift_line_numbers() {
        let entries = parse("# one\n\n# three\nname: x\n").unwrap();
        assert_eq!(entries[0].line, 4);
    }
}
