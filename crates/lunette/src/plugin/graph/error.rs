//! Operation errors and planning diagnostics emitted by the graph.

use std::{error::Error, fmt};

use crate::plugin::graph::{ContractKey, InstanceId};

/// A rejected graph operation leaves graph state unchanged.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GraphError {
    ContractConflict {
        key: ContractKey,
        owner: InstanceId,
    },
    ContractQuarantined {
        key: ContractKey,
        owner: InstanceId,
    },
    DuplicateProvided {
        key: ContractKey,
    },
    UnknownInstance(InstanceId),
    /// The instance is retired, and retirement is permanent.
    Retired(InstanceId),
    /// A cleanup inverse failed, and the instance cannot load again.
    Quarantined(InstanceId),
    /// Child installation requires a live parent activation.
    ParentInactive(InstanceId),
    ShuttingDown,
    /// An identifier counter cannot allocate another identity.
    IdExhausted,
    /// An attachment report does not match the current activation.
    StaleAction,
    /// An attachment report names an instance with no matching attachment.
    InvalidAction,
}

impl fmt::Display for GraphError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ContractConflict { key, owner } => write!(
                formatter,
                "plugin graph: contract {key} is reserved by enabled {owner}"
            ),
            Self::ContractQuarantined { key, owner } => write!(
                formatter,
                "plugin graph: contract {key} is reserved by quarantined {owner}"
            ),
            Self::DuplicateProvided { key } => write!(
                formatter,
                "plugin graph: descriptor provides {key} more than once"
            ),
            Self::UnknownInstance(instance) => {
                write!(formatter, "plugin graph: unknown {instance}")
            }
            Self::Retired(instance) => write!(formatter, "plugin graph: {instance} is retired"),
            Self::Quarantined(instance) => write!(
                formatter,
                "plugin graph: {instance} is quarantined after a cleanup failure"
            ),
            Self::ParentInactive(parent) => write!(
                formatter,
                "plugin graph: {parent} has no live activation to own a child"
            ),
            Self::ShuttingDown => write!(formatter, "plugin graph: graph is shutting down"),
            Self::IdExhausted => write!(formatter, "plugin graph: identifier space is exhausted"),
            Self::StaleAction => write!(formatter, "plugin graph: action report is stale"),
            Self::InvalidAction => write!(formatter, "plugin graph: action report is invalid"),
        }
    }
}

impl Error for GraphError {}

/// Whether a diagnostic waits for configuration or requires a change.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Severity {
    /// Configuration order can resolve the condition, such as by enabling a provider.
    Waiting,
    /// The instance cannot make progress until the configuration changes.
    Error,
}

/// Why an enabled instance cannot load or publish services.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DiagnosticKind {
    MissingProvider {
        required: ContractKey,
    },
    ProviderDisabled {
        required: ContractKey,
        provider: InstanceId,
    },
    /// A provider exposes the required name with a different schema.
    SchemaMismatch {
        required: ContractKey,
        /// The key the provider exposes instead.
        provided: ContractKey,
        provider: InstanceId,
    },
    ProviderQuarantined {
        required: ContractKey,
        provider: InstanceId,
    },
    ContractQuarantined {
        key: ContractKey,
        owner: InstanceId,
    },
    /// The declarations form a cycle, so no member can load first.
    DependencyCycle {
        /// The cycle's instance path, including its closing instance.
        instances: Vec<InstanceId>,
    },
    /// Another instance held a provided contract when the load completed, so publication failed.
    PublishConflict {
        key: ContractKey,
        owner: InstanceId,
    },
    /// No instance can begin a load again.
    ActivationsExhausted,
}

impl DiagnosticKind {
    /// Reports whether the condition resolves through ordinary configuration order.
    #[must_use]
    pub const fn severity(&self) -> Severity {
        match self {
            Self::MissingProvider { .. } | Self::ProviderDisabled { .. } => Severity::Waiting,
            Self::SchemaMismatch { .. }
            | Self::ProviderQuarantined { .. }
            | Self::ContractQuarantined { .. }
            | Self::DependencyCycle { .. }
            | Self::PublishConflict { .. }
            | Self::ActivationsExhausted => Severity::Error,
        }
    }

    /// Uses `label` to name instances.
    #[must_use]
    pub fn describe(&self, label: &dyn Fn(InstanceId) -> String) -> String {
        match self {
            Self::MissingProvider { required } => {
                format!("waiting for a provider of {required}; none is installed")
            }
            Self::ProviderDisabled { required, provider } => format!(
                "waiting for {required}; its provider {} is not enabled",
                label(*provider)
            ),
            Self::SchemaMismatch {
                required,
                provided,
                provider,
            } => format!(
                "requires {required}, but {} provides {provided}",
                label(*provider)
            ),
            Self::ProviderQuarantined { required, provider } => format!(
                "requires {required}, but its provider {} is quarantined after a cleanup failure",
                label(*provider)
            ),
            Self::ContractQuarantined { key, owner } => format!(
                "provides {key}, which quarantined {} still holds",
                label(*owner)
            ),
            Self::DependencyCycle { instances } => format!(
                "dependency cycle through {}",
                instances
                    .iter()
                    .map(|instance| label(*instance))
                    .collect::<Vec<_>>()
                    .join(" -> ")
            ),
            Self::PublishConflict { key, owner } => {
                format!("could not publish {key}, which {} holds", label(*owner))
            }
            Self::ActivationsExhausted => {
                "could not begin a load; the activation identifier space is exhausted".to_owned()
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Diagnostic {
    pub instance: InstanceId,
    pub kind: DiagnosticKind,
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "plugin graph: {}: {}",
            self.instance,
            self.kind.describe(&|instance| instance.to_string())
        )
    }
}
