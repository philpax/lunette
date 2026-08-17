//! Who is listening for each event.
//!
//! lunette's events used to be delivered to `lovr.lunwindowopened` and its
//! siblings, which gave each event exactly one handler for the whole session.
//! That is one slot for every listener there could be, so a library taking it
//! took it from the configuration: `mullion.panel` polled a claim rather than
//! handling the grant, and `mullion.error` had to call whatever handler it had
//! displaced. Listeners are peers here, and a subscription is a ticket rather
//! than a name nobody else may use.

use std::collections::HashMap;

use mlua::Function;

use crate::events::EventName;

/// A ticket naming one subscription, so it can be cancelled without the holder
/// having to identify itself by the function it registered.
///
/// Comparing functions would not do it: the same closure may be subscribed
/// twice, deliberately, and two subscriptions of one function are two
/// listeners.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SubscriptionId(u64);

/// Every listener, by the event it is waiting for.
#[derive(Debug, Default)]
pub struct Subscribers {
    listeners: HashMap<EventName, Vec<(SubscriptionId, Function)>>,
    /// Never reused, including across a reload, so a ticket held past a
    /// cancellation cannot name a later subscription.
    next: u64,
}

impl Subscribers {
    /// Adds a listener to the end of an event's list.
    pub fn add(&mut self, name: EventName, handler: Function) -> SubscriptionId {
        let id = SubscriptionId(self.next);
        self.next += 1;
        self.listeners.entry(name).or_default().push((id, handler));
        id
    }

    /// Removes a listener, if the ticket still names one.
    pub fn remove(&mut self, id: SubscriptionId) {
        for handlers in self.listeners.values_mut() {
            handlers.retain(|(held, _)| *held != id);
        }
    }

    /// Everyone waiting for an event, in the order they subscribed.
    #[must_use]
    pub fn listeners(&self, name: EventName) -> Vec<Function> {
        self.listeners
            .get(&name)
            .map(|handlers| {
                handlers
                    .iter()
                    .map(|(_, handler)| handler.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Forgets everyone. The identifiers keep climbing, so a ticket from before
    /// a reload cannot name a subscription made after it.
    pub fn clear(&mut self) {
        self.listeners.clear();
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use super::*;

    /// A `Function` needs a state, and these cases are about the bookkeeping
    /// rather than the calling, so the state is the smallest one that hands out
    /// functions.
    fn handler(lua: &mlua::Lua) -> Function {
        lua.create_function(|_, ()| Ok(()))
            .expect("a state hands out functions")
    }

    fn name() -> EventName {
        crate::events::EVENT_NAMES[0]
    }

    #[test]
    fn a_listener_is_returned_until_it_is_cancelled() {
        let lua = mlua::Lua::new();
        let mut subscribers = Subscribers::default();

        let id = subscribers.add(name(), handler(&lua));
        assert_eq!(subscribers.listeners(name()).len(), 1);

        subscribers.remove(id);
        assert!(subscribers.listeners(name()).is_empty());
    }

    #[test]
    fn listeners_are_answered_in_the_order_they_subscribed() {
        let lua = mlua::Lua::new();
        let mut subscribers = Subscribers::default();

        let first = subscribers.add(name(), handler(&lua));
        let second = subscribers.add(name(), handler(&lua));

        assert_ne!(first, second);
        assert_eq!(subscribers.listeners(name()).len(), 2);
    }

    #[test]
    fn an_event_nobody_waits_for_has_no_listeners() {
        let subscribers = Subscribers::default();
        assert!(subscribers.listeners(name()).is_empty());
    }

    #[test]
    fn cancelling_twice_removes_nothing_the_second_time() {
        let lua = mlua::Lua::new();
        let mut subscribers = Subscribers::default();

        let id = subscribers.add(name(), handler(&lua));
        let other = subscribers.add(name(), handler(&lua));
        subscribers.remove(id);
        subscribers.remove(id);

        assert_eq!(subscribers.listeners(name()).len(), 1);
        subscribers.remove(other);
        assert!(subscribers.listeners(name()).is_empty());
    }

    /// The case a reload leaves behind: a configuration holds a ticket, the
    /// reload forgets every listener, and the configuration cancels afterwards.
    #[test]
    fn a_ticket_from_before_a_reload_cancels_nothing_after_it() {
        let lua = mlua::Lua::new();
        let mut subscribers = Subscribers::default();

        let stale = subscribers.add(name(), handler(&lua));
        subscribers.clear();
        let fresh = subscribers.add(name(), handler(&lua));

        assert_ne!(stale, fresh);
        subscribers.remove(stale);
        assert_eq!(
            subscribers.listeners(name()).len(),
            1,
            "the stale ticket removed a subscription made after the reload"
        );
    }
}
