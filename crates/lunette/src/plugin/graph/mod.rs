//! Pure plugin lifecycle graph. Intents update state immediately, and planning derives actions from that state.
//! See `docs/development/architecture.md#plugin-runtime`.

mod error;
mod ids;
mod lifecycle;
mod planning;
mod snapshot;

pub use self::{
    error::{Diagnostic, DiagnosticKind, GraphError, Severity},
    ids::{ActivationId, Binding, ContractKey, InstanceId, ProviderGeneration},
    lifecycle::{
        Action, Graph, Intent, IntentState, LifecycleState, LoadOutcome, LoadResolution, Stage,
    },
    snapshot::{GraphSnapshot, InstanceSnapshot},
};

#[cfg(test)]
mod model_tests;
#[cfg(test)]
mod tests;
