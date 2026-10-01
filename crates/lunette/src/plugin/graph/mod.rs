//! Pure plugin lifecycle graph.
//!
//! The coordinator installs descriptors, applies [`Intent`]s, performs each
//! action [`Graph::next_action`] returns, and reports its completion. Intents
//! change state immediately and planning derives from that state, so there is
//! no intent queue and no work a later poll cannot find.
//!
//! An instance reserves each provided [`ContractKey`] (a name and an exact
//! schema) from enable until its attachment ends. A load action carries a
//! sorted [`Binding`] per requirement, naming the provider's
//! [`ProviderGeneration`], and the graph publishes the consumer only if every
//! provider and parent is still active. A failed load is retried only against
//! different bindings, and a cleanup failure quarantines the instance until
//! shutdown. See `docs/dev/architecture.md#plugin-runtime`.

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
