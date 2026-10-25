use super::*;

#[test]
fn consecutive_acknowledgements_accept_line_and_nul_terminated_forms() -> io::Result<()> {
    for stream in [
        b"ack\nack\nack\n".as_slice(),
        b"ack\n\0ack\n\0ack\n\0".as_slice(),
        b"ack\n\0ack\nack\n\0".as_slice(),
    ] {
        let mut parser = Acknowledgement::default();
        let mut completed = 0;
        for byte in stream {
            completed += usize::from(parser.push(*byte)?);
        }
        assert_eq!(completed, 3);
    }
    Ok(())
}

#[test]
fn newline_completes_an_ack_before_an_optional_nul_arrives() -> io::Result<()> {
    let mut parser = Acknowledgement::default();
    for byte in b"ack" {
        assert!(!parser.push(*byte)?);
    }
    assert!(parser.push(b'\n')?);
    assert!(!parser.push(0)?);
    for byte in b"ack" {
        assert!(!parser.push(*byte)?);
    }
    assert!(parser.push(b'\n')?);
    Ok(())
}

#[test]
fn malformed_acknowledgements_do_not_accept_nuls_inside_or_before_a_line() {
    for stream in [
        b"\0ack\n".as_slice(),
        b"ack\n\0\0ack\n".as_slice(),
        b"a\0ck\n".as_slice(),
        b"ac\0k\n".as_slice(),
        b"ack\0\n".as_slice(),
        b"ACK\n".as_slice(),
        b"ack \n".as_slice(),
        b"ack\r\n".as_slice(),
        b"no\n".as_slice(),
        b"\n".as_slice(),
    ] {
        let mut parser = Acknowledgement::default();
        assert!(
            stream.iter().any(|byte| parser.push(*byte).is_err()),
            "stream: {stream:?}"
        );
    }
}
