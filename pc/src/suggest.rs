//! Suggested next messages (PROTOCOL.md v1.5).
//!
//! Claude Code's own prompt suggestion only exists inside the app that shows
//! it, so the phone gets one another way: when the feature is on
//! (`mewo suggestions on`), the UserPromptSubmit hook asks Claude to end
//! its reply with a line no Markdown renderer shows,
//!
//! ```text
//! [next]: # "run the tests | commit it"
//! ```
//!
//! (a link reference definition), and the daemon takes that line out of the
//! text again: its entries become the chat item's `suggestions`.

/// How the line starts.
const MARKER: &str = "[next]: #";
const MAX_SUGGESTIONS: usize = 3;
const MAX_CHARS: usize = 120;

/// What the hook adds to a prompt.
pub const INSTRUCTION: &str = "Mewo on Fire: the user also follows this session on their phone, \
which offers suggested next messages. End your final reply of this turn with one extra line, \
after an empty line, in exactly this form:\n\
[next]: # \"first suggestion | second suggestion\"\n\
Put one to three short messages there (under 60 characters each, no double quotes) that the \
user would plausibly send next, worded as the user would type them and in the user's language: \
an answer to a question you asked, or the obvious next step. The line is not displayed; never \
mention it. Leave it out only when there is nothing sensible to suggest.";

/// `text` without its suggestion line, and the suggestions on that line.
pub fn split(text: &str) -> (String, Vec<String>) {
    let lines: Vec<&str> = text.lines().collect();
    let Some(at) = lines.iter().rposition(|l| l.trim_start().starts_with(MARKER)) else {
        return (text.to_string(), Vec::new());
    };
    let rest = lines[at].trim_start()[MARKER.len()..].trim();
    // "…" or (…) around the entries; taken as they are without either.
    let inner = match (rest.chars().next(), rest.chars().last()) {
        (Some('"'), Some('"')) | (Some('('), Some(')')) | (Some('\''), Some('\'')) if rest.len() >= 2 => {
            &rest[1..rest.len() - 1]
        }
        _ => rest,
    };
    let suggestions: Vec<String> = inner
        .split('|')
        // Quotes around an entry (Claude sometimes adds them) are not part of it.
        .map(|s| s.trim().trim_matches(|c| matches!(c, '"' | '\'' | '`' | '\u{201C}' | '\u{201D}')).trim())
        .map(|s| s.chars().take(MAX_CHARS).collect::<String>())
        .filter(|s| !s.is_empty())
        .take(MAX_SUGGESTIONS)
        .collect();
    let mut kept: Vec<&str> = lines[..at].to_vec();
    kept.extend_from_slice(&lines[at + 1..]);
    (kept.join("\n").trim_end().to_string(), suggestions)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_the_line_out() {
        let (text, s) = split("All tests pass.\n\n[next]: # \"commit it | push\"");
        assert_eq!(text, "All tests pass.");
        assert_eq!(s, vec!["commit it", "push"]);
    }

    #[test]
    fn other_wrappings_and_limits() {
        let (text, s) = split("Done.\n\n  [next]: # (yes | no | maybe | never)\n");
        assert_eq!(text, "Done.");
        assert_eq!(s, vec!["yes", "no", "maybe"]);
        let (_, s) = split("[next]: # نعم | لا");
        assert_eq!(s, vec!["نعم", "لا"]);
        let (_, s) = split("[next]: # \"\"write the migration\" | 'flip it'\"");
        assert_eq!(s, vec!["write the migration", "flip it"]);
        let (text, s) = split("Done.\n\n[next]: # \"\"");
        assert_eq!((text.as_str(), s.len()), ("Done.", 0));
    }

    #[test]
    fn text_without_one_is_untouched() {
        let original = "See [next]: the docs.\n\n```\n[x]: # \"y\"\n```";
        let (text, s) = split(original);
        assert_eq!(text, original);
        assert!(s.is_empty());
    }
}
