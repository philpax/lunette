//! Linux-only: `lunctl`, the client for lunette's control socket.
//!
//! Sends a Lua chunk to the running session and prints what came back
//! ([the Lua API](../../../docs/lua-api.md#lunctl)). A top-level string
//! prints without quotes, so `$(lunctl 'return win.title')` captures the title
//! rather than the title in quotes. A string inside a table is quoted, because
//! there it has to be told apart from a key.
//!
//! Three modes follow the same design: chunks named on the command line,
//! chunks read from standard input, and an interactive prompt when standard
//! input is a terminal.
//!
//! Exit statuses enumerate distinct outcomes so that a script can branch on
//! whether a chunk raised, failed to compile, ran past its budget, returned
//! unrepresentable data, was rejected before evaluation, or could not reach
//! the session. [`Status`] documents each case.
//!
//! The wire format is shared with `lunette`. A separate crate would either
//! duplicate the codec or depend on `lunette`, which is what this does as a
//! second binary target within the crate. A protocol with multiple independent
//! implementations is a maintenance hazard.
//!
//! This is an application entry point, so it reads the environment. Nothing it
//! learns from it goes anywhere but into [`socket_path`].

use std::{
    env,
    ffi::OsString,
    fmt::Write as _,
    io::{self, BufRead, IsTerminal, Read, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    process::ExitCode,
};

use lunette::control::{
    identifier::is_identifier,
    socket::{DIRECTORY_NAME, SOCKET_NAME},
    wire::{
        Handle, Key, MAX_FRAME, Reply, TableValue, Value, WireError, read_reply, write_request,
    },
};

fn main() -> ExitCode {
    let arguments: Vec<OsString> = env::args_os().skip(1).collect();
    let invocation = match parse(&arguments) {
        Ok(invocation) => invocation,
        Err(usage) => {
            eprintln!("lunctl: {usage}");
            eprintln!("{HELP}");
            return Status::Usage.into();
        }
    };

    let socket = match invocation.socket {
        Some(path) => path,
        None => match socket_path(env::var_os(XDG_RUNTIME_DIR).as_deref().map(Path::new)) {
            Some(path) => path,
            None => {
                eprintln!(
                    "lunctl: {XDG_RUNTIME_DIR} does not name an absolute path, so the control \
                     socket cannot be found; pass --socket to say where it is"
                );
                return Status::Unreachable.into();
            }
        },
    };

    match invocation.mode {
        Mode::Help => {
            println!("{HELP}");
            Status::Ok.into()
        }
        Mode::Chunks(chunks) => run_chunks(&socket, &chunks).into(),
        Mode::Stdin => match read_stdin() {
            Ok(chunk) => run_chunks(&socket, std::slice::from_ref(&chunk)).into(),
            Err(error) => {
                eprintln!("lunctl: the chunk could not be read from standard input: {error}");
                Status::Usage.into()
            }
        },
        Mode::Repl => repl(&socket).into(),
    }
}

/// Where the runtime directory is named, as a plain string.
const XDG_RUNTIME_DIR: &str = "XDG_RUNTIME_DIR";

const HELP: &str = "usage: lunctl [--socket PATH] [CHUNK ...]

Evaluates a Lua chunk in the running lunette session and prints the result.

  lunctl 'return #lunette.windows()'   evaluate each argument in turn
  lunctl < script.lua                  evaluate what arrives on standard input
  lunctl                               an interactive prompt, on a terminal

  --socket PATH   the control socket, instead of
                  $XDG_RUNTIME_DIR/lunette/lunette-0.sock
  --help          this message

exit status
  0  the chunk ran
  1  the chunk raised
  2  the chunk did not compile
  3  the chunk ran past its time budget and was abandoned
  4  the chunk returned something the protocol cannot carry, or too much of it
  5  the session did not evaluate it
  6  the session could not be reached
 64  lunctl was invoked wrongly";

/// What one invocation of `lunctl` exits with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Status {
    Ok,
    Raised,
    DidNotCompile,
    Abandoned,
    Unrepresentable,
    NotEvaluated,
    Unreachable,
    /// `EX_USAGE`, as `sysexits.h` numbers it.
    Usage,
}

impl From<Status> for ExitCode {
    fn from(status: Status) -> Self {
        Self::from(match status {
            Status::Ok => 0,
            Status::Raised => 1,
            Status::DidNotCompile => 2,
            Status::Abandoned => 3,
            Status::Unrepresentable => 4,
            Status::NotEvaluated => 5,
            Status::Unreachable => 6,
            Status::Usage => 64,
        })
    }
}

/// What the command line asked for, after argument parsing.
#[derive(Debug, PartialEq, Eq)]
struct Invocation {
    socket: Option<PathBuf>,
    mode: Mode,
}

/// Which of the three modes this invocation is in.
#[derive(Debug, PartialEq, Eq)]
enum Mode {
    Help,
    /// Chunks named on the command line, evaluated in order.
    Chunks(Vec<String>),
    /// One chunk read from standard input.
    Stdin,
    Repl,
}

/// Reads the command line arguments and decides which mode to run in.
fn parse(arguments: &[OsString]) -> Result<Invocation, String> {
    let mut socket = None;
    let mut chunks = Vec::new();
    let mut help = false;
    let mut rest = arguments.iter();

    while let Some(argument) = rest.next() {
        match argument.to_str() {
            Some("--help" | "-h") => help = true,
            Some("--socket") => {
                let path = rest
                    .next()
                    .ok_or_else(|| "--socket needs a path after it".to_owned())?;
                socket = Some(PathBuf::from(path));
            }
            Some(flag) if flag.starts_with("--") => {
                return Err(format!("{flag} is not an option lunctl takes"));
            }
            _ => {
                let chunk = argument.to_str().ok_or_else(|| {
                    "a chunk has to be valid utf-8; lua source in another encoding is a mistake \
                     rather than a dialect"
                        .to_owned()
                })?;
                chunks.push(chunk.to_owned());
            }
        }
    }

    let mode = if help {
        Mode::Help
    } else if chunks.is_empty() {
        if io::stdin().is_terminal() {
            Mode::Repl
        } else {
            Mode::Stdin
        }
    } else {
        Mode::Chunks(chunks)
    };

    Ok(Invocation { socket, mode })
}

/// The control socket path, computed from the runtime directory value.
fn socket_path(runtime_directory: Option<&Path>) -> Option<PathBuf> {
    let runtime_directory = runtime_directory.filter(|path| path.is_absolute())?;
    Some(runtime_directory.join(DIRECTORY_NAME).join(SOCKET_NAME))
}

fn read_stdin() -> io::Result<String> {
    let mut chunk = String::new();
    io::stdin().read_to_string(&mut chunk)?;
    Ok(chunk)
}

/// Evaluates each chunk in turn, stopping at the first that did not run.
fn run_chunks(socket: &Path, chunks: &[String]) -> Status {
    for chunk in chunks {
        let status = evaluate_and_report(socket, chunk);
        if status != Status::Ok {
            return status;
        }
    }
    Status::Ok
}

/// The interactive prompt.
///
/// Relies on `rlwrap lunctl` for line editing and history rather than
/// implementing those features itself.
fn repl(socket: &Path) -> Status {
    let stdin = io::stdin();
    let mut line = String::new();

    loop {
        print!("{PROMPT}");
        if let Err(error) = io::stdout().flush() {
            eprintln!("lunctl: the prompt could not be written: {error}");
            return Status::Usage;
        }

        line.clear();
        match stdin.lock().read_line(&mut line) {
            Ok(0) => return Status::Ok,
            Ok(_) => {}
            Err(error) => {
                eprintln!("lunctl: the line could not be read: {error}");
                return Status::Usage;
            }
        }

        let chunk = line.trim();
        if chunk.is_empty() {
            continue;
        }

        // The expression first, like Lua's own standalone interpreter does, so
        // that typing `lunette.windows()` prints the windows rather than
        // evaluating a call statement and printing nothing. A line that is a
        // statement does not compile with `return` in front of it, and is then
        // sent as it was typed.
        let expression = format!("return {chunk}");
        match exchange(socket, &expression) {
            Ok(Reply::LoadError(_)) => report(&exchange(socket, chunk)),
            other => report(&other),
        };
    }
}

const PROMPT: &str = "lunctl> ";

/// Sends one chunk, prints what came back, and returns the exit status.
fn evaluate_and_report(socket: &Path, chunk: &str) -> Status {
    report(&exchange(socket, chunk))
}

/// Sends one request and reads the reply, over a single connection.
fn exchange(socket: &Path, chunk: &str) -> Result<Reply, Unanswered> {
    let mut stream = UnixStream::connect(socket).map_err(|error| {
        Unanswered::Unreachable(format!(
            "{} could not be reached, so there is no session to ask: {error}",
            socket.display()
        ))
    })?;

    match write_request(&mut stream, chunk) {
        Ok(()) => {}
        Err(WireError::TooLarge { length }) => return Err(Unanswered::ChunkTooLarge { length }),
        Err(error) => return Err(Unanswered::Unreachable(error.to_string())),
    }

    read_reply(&mut stream).map_err(|error| Unanswered::Unreachable(error.to_string()))
}

/// Why an exchange produced no reply.
#[derive(Debug)]
enum Unanswered {
    ChunkTooLarge { length: usize },
    /// The socket, the write, or the read failed.
    Unreachable(String),
}

/// Prints a reply and returns the exit status.
fn report(reply: &Result<Reply, Unanswered>) -> Status {
    let reply = match reply {
        Ok(reply) => reply,
        Err(Unanswered::ChunkTooLarge { length }) => {
            eprintln!(
                "lunctl: the chunk is {length} bytes and one message carries at most {MAX_FRAME}, \
                 so it was not sent; put it in a file and have the chunk load that"
            );
            return Status::Usage;
        }
        Err(Unanswered::Unreachable(message)) => {
            eprintln!("lunctl: {message}");
            return Status::Unreachable;
        }
    };

    match reply {
        Reply::Returned(values) => {
            for value in values {
                println!("{}", top_level(value));
            }
            Status::Ok
        }
        Reply::LoadError(message) => {
            eprintln!("lunctl: the chunk did not compile: {message}");
            Status::DidNotCompile
        }
        Reply::RuntimeError(message) => {
            eprintln!("lunctl: the chunk raised: {message}");
            Status::Raised
        }
        Reply::Abandoned { after } => {
            eprintln!(
                "lunctl: the chunk ran for {after:?} and was abandoned; the budget is best-effort, \
                 so a chunk that catches its own abort can outlast it"
            );
            Status::Abandoned
        }
        Reply::Unrepresentable(message) => {
            // Printed as it stands. The serialiser's message already leads with
            // this subsystem's prefix, and adding a second one would say
            // `lunctl: lunctl:`.
            eprintln!("{message}");
            Status::Unrepresentable
        }
        Reply::Busy => {
            eprintln!("lunctl: the session already has as many chunks queued as it will hold");
            Status::NotEvaluated
        }
        Reply::Unanswered => {
            eprintln!(
                "lunctl: the session did not answer; it may have stopped drawing, and whether the \
                 chunk ran is not known"
            );
            Status::NotEvaluated
        }
        Reply::Oversized { length } => {
            eprintln!(
                "lunctl: the chunk ran, and its answer is {length} bytes; one message carries at \
                 most {MAX_FRAME}, so none of it came back. Return less of it — a count, a field, \
                 or a slice — rather than the whole structure"
            );
            Status::Unrepresentable
        }
        Reply::Malformed(message) => {
            eprintln!(
                "lunctl: the session could not read the request, and was not asked: {message}"
            );
            Status::Usage
        }
        Reply::Incompatible { session, client } => {
            eprintln!(
                "lunctl: this lunctl speaks protocol version {client} and the session speaks \
                 {session}; they are from different builds"
            );
            Status::NotEvaluated
        }
    }
}

/// A returned value, rendered at the top level where a string prints bare.
fn top_level(value: &Value) -> String {
    match value {
        Value::String(bytes) => String::from_utf8_lossy(bytes).into_owned(),
        other => render(other, 0),
    }
}

/// One value, indented `depth` levels.
fn render(value: &Value, depth: usize) -> String {
    match value {
        Value::Nil => "nil".to_owned(),
        Value::Boolean(answer) => answer.to_string(),
        Value::Integer(number) => number.to_string(),
        Value::Float(number) => number_text(*number),
        Value::String(bytes) => quoted(bytes),
        Value::Table(table) => table_text(table, depth),
        Value::Handle(handle) => handle_text(handle),
    }
}

/// A number as Lua spells it, rather than as Rust does.
fn number_text(number: f64) -> String {
    if number.is_nan() {
        return "nan".to_owned();
    }
    if number.is_infinite() {
        return if number.is_sign_negative() {
            "-inf"
        } else {
            "inf"
        }
        .to_owned();
    }
    number.to_string()
}

/// A Lua string, quoted and escaped for paste-back into a chunk.
fn quoted(bytes: &[u8]) -> String {
    let mut rendered = String::with_capacity(bytes.len() + 2);
    rendered.push('\'');
    match str::from_utf8(bytes) {
        Ok(text) => {
            for character in text.chars() {
                match character {
                    '\'' => rendered.push_str("\\'"),
                    '\\' => rendered.push_str("\\\\"),
                    '\n' => rendered.push_str("\\n"),
                    '\t' => rendered.push_str("\\t"),
                    '\r' => rendered.push_str("\\r"),
                    character if character.is_control() => {
                        let _ = write!(rendered, "\\x{:02x}", character as u32);
                    }
                    character => rendered.push(character),
                }
            }
        }
        Err(_) => {
            for byte in bytes {
                let _ = write!(rendered, "\\x{byte:02x}");
            }
        }
    }
    rendered.push('\'');
    rendered
}

/// A table, one entry a line.
fn table_text(table: &TableValue, depth: usize) -> String {
    if table.array.is_empty() && table.entries.is_empty() {
        return "{}".to_owned();
    }

    let inner = INDENT.repeat(depth + 1);
    let mut rendered = String::from("{\n");
    for value in &table.array {
        let _ = writeln!(rendered, "{inner}{},", render(value, depth + 1));
    }
    for (key, value) in &table.entries {
        let _ = writeln!(
            rendered,
            "{inner}{} = {},",
            key_text(key),
            render(value, depth + 1)
        );
    }
    let _ = write!(rendered, "{}}}", INDENT.repeat(depth));
    rendered
}

const INDENT: &str = "  ";

/// A key, as it would be written in a table constructor.
fn key_text(key: &Key) -> String {
    match key {
        Key::String(bytes) => match str::from_utf8(bytes) {
            Ok(name) if is_identifier(name) => name.to_owned(),
            _ => format!("[{}]", quoted(bytes)),
        },
        Key::Integer(index) => format!("[{index}]"),
        Key::Float(number) => format!("[{}]", number_text(*number)),
        Key::Boolean(answer) => format!("[{answer}]"),
    }
}

/// A handle, rendered as its kind and its identifier.
fn handle_text(handle: &Handle) -> String {
    match &handle.id {
        Some(id) => format!("<{} {id}>", handle.kind),
        None => format!("<{}>", handle.kind),
    }
}

#[cfg(test)]
mod tests {
    use lunette::control::wire::{HandleId, HandleKind};
    use pretty_assertions::assert_eq;

    use super::*;

    fn arguments(given: &[&str]) -> Vec<OsString> {
        given.iter().map(OsString::from).collect()
    }

    #[test]
    fn a_chunk_argument_is_the_chunk_mode() {
        assert_eq!(
            parse(&arguments(&["return 1"])),
            Ok(Invocation {
                socket: None,
                mode: Mode::Chunks(vec!["return 1".to_owned()]),
            })
        );
    }

    #[test]
    fn several_chunk_arguments_are_evaluated_in_order() {
        let Ok(Invocation {
            mode: Mode::Chunks(chunks),
            ..
        }) = parse(&arguments(&["return 1", "return 2"]))
        else {
            panic!("two chunks are two chunks");
        };
        assert_eq!(chunks, vec!["return 1".to_owned(), "return 2".to_owned()]);
    }

    #[test]
    fn the_socket_can_be_named_instead_of_resolved() {
        let Ok(invocation) = parse(&arguments(&["--socket", "/tmp/x.sock", "return 1"])) else {
            panic!("it parses");
        };
        assert_eq!(invocation.socket, Some(PathBuf::from("/tmp/x.sock")));
    }

    #[test]
    fn a_socket_flag_with_nothing_after_it_is_a_usage_error() {
        assert!(parse(&arguments(&["--socket"])).is_err());
    }

    #[test]
    fn an_option_lunctl_does_not_take_is_a_usage_error() {
        assert!(parse(&arguments(&["--eval"])).is_err());
    }

    #[test]
    fn help_wins_over_a_chunk() {
        let Ok(invocation) = parse(&arguments(&["return 1", "--help"])) else {
            panic!("it parses");
        };
        assert_eq!(invocation.mode, Mode::Help);
    }

    #[test]
    fn the_socket_path_is_inside_the_private_directory() {
        assert_eq!(
            socket_path(Some(Path::new("/run/user/1000"))),
            Some(PathBuf::from("/run/user/1000/lunette/lunette-0.sock")),
        );
    }

    #[test]
    fn a_relative_or_absent_runtime_directory_names_nothing() {
        assert_eq!(socket_path(Some(Path::new("run/user"))), None);
        assert_eq!(socket_path(None), None);
    }

    #[test]
    fn every_status_has_its_own_exit_code() {
        let statuses = [
            Status::Ok,
            Status::Raised,
            Status::DidNotCompile,
            Status::Abandoned,
            Status::Unrepresentable,
            Status::NotEvaluated,
            Status::Unreachable,
            Status::Usage,
        ];
        let codes: Vec<String> = statuses
            .iter()
            .map(|status| format!("{:?}", ExitCode::from(*status)))
            .collect();
        let mut unique = codes.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(
            unique.len(),
            statuses.len(),
            "a script branches on these, so no two may collide: {codes:?}"
        );
    }

    #[test]
    fn a_top_level_string_prints_bare_and_a_nested_one_prints_quoted() {
        assert_eq!(
            top_level(&Value::String(b"a terminal".to_vec())),
            "a terminal"
        );
        assert_eq!(
            render(&Value::String(b"a terminal".to_vec()), 0),
            "'a terminal'"
        );
    }

    #[test]
    fn a_table_prints_its_array_part_then_its_named_entries() {
        let table = Value::Table(TableValue {
            array: vec![Value::Integer(1), Value::Integer(2)],
            entries: vec![(Key::String(b"x".to_vec()), Value::Integer(3))],
        });

        assert_eq!(render(&table, 0), "{\n  1,\n  2,\n  x = 3,\n}");
    }

    #[test]
    fn a_nested_table_is_indented() {
        let table = Value::Table(TableValue {
            array: Vec::new(),
            entries: vec![(
                Key::String(b"size".to_vec()),
                Value::Table(TableValue {
                    array: vec![Value::Integer(1920)],
                    entries: Vec::new(),
                }),
            )],
        });

        assert_eq!(render(&table, 0), "{\n  size = {\n    1920,\n  },\n}");
    }

    #[test]
    fn an_empty_table_prints_on_one_line() {
        assert_eq!(render(&Value::Table(TableValue::default()), 0), "{}");
    }

    #[test]
    fn a_key_that_is_not_a_name_is_written_as_a_subscript() {
        assert_eq!(key_text(&Key::String(b"appId".to_vec())), "appId");
        assert_eq!(
            key_text(&Key::String(b"with space".to_vec())),
            "['with space']"
        );
        // A reserved word is not a name: `end = 1` does not parse, and what is
        // printed is promised to.
        assert_eq!(key_text(&Key::String(b"end".to_vec())), "['end']");
        assert_eq!(key_text(&Key::String(b"function".to_vec())), "['function']");
        assert_eq!(key_text(&Key::Integer(4)), "[4]");
        assert_eq!(key_text(&Key::Boolean(true)), "[true]");
    }

    #[test]
    fn a_handle_prints_its_kind_and_id() {
        assert_eq!(
            handle_text(&Handle {
                kind: HandleKind::Window,
                id: Some(HandleId::Number(3)),
            }),
            "<window 3>"
        );
        assert_eq!(
            handle_text(&Handle {
                kind: HandleKind::Monitor,
                id: Some(HandleId::Text(b"Acme X24".to_vec())),
            }),
            "<monitor Acme X24>"
        );
        assert_eq!(
            handle_text(&Handle {
                kind: HandleKind::Sink,
                id: None,
            }),
            "<sink>"
        );
    }

    #[test]
    fn a_number_prints_the_way_lua_spells_it() {
        assert_eq!(number_text(1.5), "1.5");
        assert_eq!(number_text(f64::INFINITY), "inf");
        assert_eq!(number_text(f64::NEG_INFINITY), "-inf");
        assert_eq!(number_text(f64::NAN), "nan");
    }

    #[test]
    fn a_string_that_is_not_text_prints_as_bytes_rather_than_being_replaced() {
        // What is printed can be pasted back into a chunk and mean the same.
        assert_eq!(quoted(&[0xff, 0xfe]), r"'\xff\xfe'");
        assert_eq!(quoted(b"a\nb"), r"'a\nb'");
        assert_eq!(quoted(b"it's"), r"'it\'s'");
    }
}
