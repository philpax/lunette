//! The decisions the selection bridge makes, without a host or a client.
//!
//! Everything here is a pure function of the bridge's recorded state, which is
//! what makes the degenerate cases testable at all: an empty selection, a MIME
//! type nothing offers, and a read that outlived the selection it was made
//! against need no desktop session to reproduce.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use pretty_assertions::assert_eq;

use super::*;
use crate::state::DEFAULT_SEAT;

/// A bridge attached to the default seat with no host connection.
///
/// The host is absent because nothing here calls it: [`SelectionBridge::resolve`]
/// decides whether a read is worth making, and only then is a host asked.
fn bridge() -> SelectionBridge {
    SelectionBridge::new(Some(DEFAULT_SEAT), None)
}

fn mime(name: &str) -> MimeType {
    MimeType::new(name).expect("a non-empty mime type")
}

fn offer(kind: SelectionKind, id: OfferId, mimes: &[&str]) -> HostOffer {
    HostOffer {
        kind,
        offer: id,
        mimes: mimes.iter().copied().map(mime).collect(),
    }
}

#[test]
fn a_mime_type_rejects_what_no_source_could_be_asked_for() {
    assert_eq!(MimeType::new(""), None);
    assert_eq!(MimeType::new("   "), None);
    assert_eq!(
        MimeType::new("text/plain").map(MimeType::into_string),
        Some("text/plain".to_owned())
    );
}

#[test]
fn a_mime_type_is_matched_byte_for_byte() {
    // Case folding here would make lunette answer a request no other compositor
    // would, and the reply would then be a type the client did not ask for.
    let held = offer(SelectionKind::Clipboard, first_offer(), &["UTF8_STRING"]);

    assert!(held.carries("UTF8_STRING"));
    assert!(!held.carries("utf8_string"));
}

#[test]
fn offer_identifiers_never_repeat() {
    let counter = OfferCounter::new();
    let issued: Vec<OfferId> = (0..8).map(|_| counter.next()).collect();

    for pair in issued.windows(2) {
        assert!(
            pair[1] > pair[0],
            "{:?} did not advance past {:?}",
            pair[1],
            pair[0]
        );
    }
}

#[test]
fn an_empty_selection_is_refused_rather_than_read() {
    // The host has copied nothing. A client that pastes gets an empty paste,
    // and no descriptor is handed to a connection that has nothing to write.
    let bridge = bridge();
    let asked = offer(SelectionKind::Clipboard, first_offer(), &["text/plain"]);

    assert_eq!(
        bridge.resolve(&asked, "text/plain"),
        Err(Refusal::NoSelection)
    );
}

#[test]
fn a_mime_type_the_offer_does_not_carry_is_refused_rather_than_substituted() {
    // The case the phase names: a selection offering nothing lunette's client
    // asked for. Answering with the nearest text type would paste bytes in an
    // encoding the client did not ask for, which is silent corruption.
    let mut bridge = bridge();
    let id = first_offer();
    let held = offer(SelectionKind::Clipboard, id, &["image/png"]);
    bridge.remember(held.clone());

    assert_eq!(
        bridge.resolve(&held, "text/plain;charset=utf-8"),
        Err(Refusal::Unrepresentable)
    );
    assert_eq!(
        bridge.resolve(&held, "image/png"),
        Ok((SelectionKind::Clipboard, id, mime("image/png"))),
        "the type it does carry still resolves"
    );
}

#[test]
fn an_offer_carrying_no_mime_types_at_all_refuses_everything() {
    let mut bridge = bridge();
    let held = offer(SelectionKind::Clipboard, first_offer(), &[]);
    bridge.remember(held.clone());

    assert_eq!(
        bridge.resolve(&held, "text/plain"),
        Err(Refusal::Unrepresentable)
    );
}

#[test]
fn a_read_of_a_selection_that_was_replaced_is_refused_rather_than_answered() {
    // A client holding a `wl_data_offer` from before the user copied something
    // else. Answering would paste the new selection under the old offer, which
    // is a paste of something the user never asked for.
    let counter = OfferCounter::new();
    let mut bridge = bridge();
    let stale = offer(SelectionKind::Clipboard, counter.next(), &["text/plain"]);
    bridge.remember(stale.clone());
    bridge.remember(offer(
        SelectionKind::Clipboard,
        counter.next(),
        &["text/plain"],
    ));

    assert_eq!(bridge.resolve(&stale, "text/plain"), Err(Refusal::Stale));
}

#[test]
fn a_selection_cleared_while_a_read_is_in_flight_is_refused() {
    let mut bridge = bridge();
    let held = offer(SelectionKind::Clipboard, first_offer(), &["text/plain"]);
    bridge.remember(held.clone());
    bridge.forget(SelectionKind::Clipboard);

    assert_eq!(
        bridge.resolve(&held, "text/plain"),
        Err(Refusal::NoSelection)
    );
}

#[test]
fn the_two_selections_do_not_interfere() {
    let counter = OfferCounter::new();
    let mut bridge = bridge();
    let clipboard = offer(SelectionKind::Clipboard, counter.next(), &["text/plain"]);
    let primary = offer(SelectionKind::Primary, counter.next(), &["text/html"]);
    bridge.remember(clipboard.clone());
    bridge.remember(primary.clone());

    bridge.forget(SelectionKind::Clipboard);

    assert_eq!(
        bridge.resolve(&clipboard, "text/plain"),
        Err(Refusal::NoSelection)
    );
    assert!(
        bridge.resolve(&primary, "text/html").is_ok(),
        "clearing the clipboard took the primary selection with it"
    );
}

#[test]
fn only_the_bridged_seat_is_bridged() {
    let bridge = bridge();
    let other = SeatId::new(DEFAULT_SEAT.get() + 1).expect("non-zero");

    assert!(bridge.bridges(DEFAULT_SEAT));
    assert!(!bridge.bridges(other));
    assert_eq!(bridge.seat(), Some(DEFAULT_SEAT));
}

#[test]
fn losing_the_host_forgets_everything_it_was_offering() {
    let mut bridge = bridge();
    let held = offer(SelectionKind::Clipboard, first_offer(), &["text/plain"]);
    bridge.remember(held.clone());

    bridge.lose_host();

    assert_eq!(bridge.offer(SelectionKind::Clipboard), None);
    assert_eq!(
        bridge.resolve(&held, "text/plain"),
        Err(Refusal::NoSelection)
    );
}

/// One identifier, for a test that only needs the offers to be distinguishable
/// from each other rather than from a sequence.
fn first_offer() -> OfferId {
    OfferCounter::new().next()
}
