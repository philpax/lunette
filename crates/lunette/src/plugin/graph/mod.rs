//! Pure plugin lifecycle graph.
//!
//! Intents update state immediately, and planning derives actions from that state.
//! Enabled instances reserve provided contracts until disable or disposal takes effect and the
//! attachment ends. Quarantined instances retain reservations until runtime shutdown.
//! Each load binding names the provider generation that satisfies one requirement.
//! Publication requires every provider and parent to remain active. Failed loads retry
//! when bindings change. Failed cleanup quarantines instances until shutdown. See
//! `docs/dev/architecture.md#plugin-runtime`.

mod error;
mod ids;
mod lifecycle;
mod planning;

pub use self::{
    error::{Diagnostic, DiagnosticKind, GraphError, Severity},
    ids::{ActivationId, Binding, ContractKey, InstanceId, ProviderGeneration},
    lifecycle::{
        Action, Graph, Intent, IntentState, LifecycleState, LoadOutcome, LoadResolution, Stage,
    },
};

#[cfg(test)]
mod model_tests;
#[cfg(test)]
mod tests;
