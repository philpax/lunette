use std::io;

#[derive(Default)]
pub(super) struct Acknowledgement {
    state: State,
}

impl Acknowledgement {
    /// Returns true once a complete acknowledgement arrives.
    pub(super) fn push(&mut self, byte: u8) -> io::Result<bool> {
        // perf can write sizeof("ack\n"), leaving its NUL after the completed line.
        // Remember that one optional byte across commands without waiting for it.
        if matches!(self.state, State::TrailingNul) && byte == 0 {
            self.state = State::Start;
            return Ok(false);
        }
        let (expected, next) = match self.state {
            State::Start | State::TrailingNul => (b'a', State::MatchedA),
            State::MatchedA => (b'c', State::MatchedAc),
            State::MatchedAc => (b'k', State::MatchedAck),
            State::MatchedAck => (b'\n', State::TrailingNul),
        };
        if byte != expected {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("perf acknowledgement: byte is {byte:#04x}, expected {expected:#04x}"),
            ));
        }
        self.state = next;
        Ok(matches!(self.state, State::TrailingNul))
    }
}

#[derive(Clone, Copy, Default)]
enum State {
    #[default]
    Start,
    MatchedA,
    MatchedAc,
    MatchedAck,
    TrailingNul,
}
