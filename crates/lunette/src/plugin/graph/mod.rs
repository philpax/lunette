//! Pure plugin lifecycle graph.
//!
//! The graph is a coordinator-facing functional core. Install descriptors with
//! [`Graph::install`], submit [`Intent`] values with [`Graph::enqueue`], and
//! repeatedly ask [`Graph::next_action`] for the next side effect. The
//! coordinator performs `BeginLoad` or `BeginUnload`, then reports the matching
//! activation through [`Graph::complete_load`] or [`Graph::complete_unload`].
//!
//! A contract is [`ContractKey`] (a name plus an exact schema). Providers reserve
//! their names transactionally at install time. A load action contains a sorted,
//! exact [`Binding`] for every requirement, including the provider's current
//! [`ProviderGeneration`]. The coordinator must pass those bindings back to
//! [`Graph::validate_attachment`] when invoking loading, active, or unloading
//! callbacks. Loading and active code may read only the allocation represented by
//! the token; unloading retains read authority for that same allocation until
//! cleanup completes.
//!
//! The graph publishes no consumer until its load succeeds, its enable intent is
//! still present, every provider is still active at the allocated generation, and
//! its parent is active. Disable, reload, dispose, and shutdown drain dependents
//! before providers and children before parents. A reentrant intent therefore
//! cancels a load before publication instead of exposing a transient consumer.
//!
//! The queue is bounded by the value passed to [`Graph::new`]. Requests for the
//! same instance coalesce, and shutdown takes priority. Once the queue reports
//! [`GraphError::QueueExhausted`], no new activation starts until
//! [`Graph::resume_after_queue_exhaustion`] or shutdown. Cleanup failure leaves
//! the instance and its contract reservations quarantined; only an explicit
//! retry intent. A cleanup failure remains quarantined for the runtime; shutdown
//! releases the quarantined graph records without retrying plugin cleanup.

mod error;
mod ids;
#[path = "graph.rs"]
mod lifecycle;

pub use self::{
    error::GraphError,
    ids::{ActivationId, Binding, ContractKey, InstanceId, ProviderGeneration},
    lifecycle::{
        Action, AttachmentState, AttachmentView, Graph, Intent, IntentState, LifecycleState,
        LoadOutcome,
    },
};

#[cfg(test)]
mod tests;
