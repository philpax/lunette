//! Pure plugin lifecycle graph.
//!
//! The graph is a coordinator-facing functional core. Install descriptors with
//! [`Graph::install`], apply [`Intent`] values with [`Graph::request`], and
//! repeatedly ask [`Graph::next_action`] for the next side effect. The
//! coordinator performs `BeginLoad` or `BeginUnload`, then reports the matching
//! activation through [`Graph::complete_load`] or [`Graph::complete_unload`].
//! Intents change state immediately; planning is derived from that state, so
//! there is no intent queue to exhaust and no work that a later poll cannot
//! find.
//!
//! A contract is [`ContractKey`] (a name plus an exact schema). An instance
//! reserves its provided keys from the moment an enable takes effect until a
//! disable or disposal has taken effect and its attachment has ended.
//! Installation reserves nothing. Reservations are keyed by name and schema,
//! so `x@1` and `x@2` can be held by different instances or by one. A load
//! action contains a sorted, exact [`Binding`] for every requirement,
//! including the provider's current [`ProviderGeneration`]. The coordinator
//! passes those bindings back to [`Graph::validate_attachment`] when invoking
//! loading, active, or unloading callbacks.
//!
//! The graph publishes no consumer unless its load succeeds, its enable intent
//! still holds, and every provider and its parent is active and will not
//! unload. Disable, reload, dispose, and shutdown drain dependents before
//! providers and children before parents. A child belongs to the activation of
//! its parent that installed it, and is retired when that activation ends,
//! including when the load fails or is cancelled. Retirement is permanent.
//!
//! A failed load is retried when the bindings it would receive differ from the
//! ones it failed against, and never against the same ones. A cleanup failure
//! quarantines the instance when its allocation ends: it never loads again,
//! has no allocation, and so neither pins its providers nor its parent, but it
//! keeps its contract reservations until shutdown completes.

mod error;
mod ids;
mod lifecycle;
mod planning;

pub use self::{
    error::{Diagnostic, DiagnosticKind, GraphError, Severity},
    ids::{ActivationId, Binding, ContractKey, InstanceId, ProviderGeneration},
    lifecycle::{
        Action, AttachmentState, AttachmentView, Graph, Intent, IntentState, LifecycleState,
        LoadOutcome, LoadResolution,
    },
};

#[cfg(test)]
mod model_tests;
#[cfg(test)]
mod tests;
