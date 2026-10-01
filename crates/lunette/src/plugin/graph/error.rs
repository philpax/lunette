//! Operation errors and planning diagnostics emitted by the graph.

use std::{error::Error, fmt};

use crate::plugin::graph::{ContractKey, InstanceId};

/// A graph operation was rejected without changing the graph.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GraphError {
    /// Another enabled instance already holds the reservation for a provided contract.
    ContractConflict {
        /// The contested contract, by name and schema.
        key: ContractKey,
        /// The enabled instance that holds the reservation.
        owner: InstanceId,
    },
    /// A quarantined instance holds the reservation for a provided contract.
    ContractQuarantined {
        /// The contested contract, by name and schema.
        key: ContractKey,
        /// The quarantined instance that holds the reservation.
        owner: InstanceId,
    },
    /// A descriptor provides the same contract key more than once.
    DuplicateProvided {
        /// The duplicated contract key.
        key: ContractKey,
    },
    /// An operation references an instance the graph does not hold.
    UnknownInstance(InstanceId),
    /// The instance is retired, and retirement is permanent.
    Retired(InstanceId),
    /// The instance's cleanup failed, so it can never be loaded again.
    Quarantined(InstanceId),
    /// A child can be installed only under a parent with a live activation.
    ParentInactive(InstanceId),
    /// The graph is shutting down and accepts no installation or intent.
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

/// How a diagnostic should be surfaced.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Severity {
    /// The instance is waiting for a condition that ordinary configuration
    /// order produces, such as a provider that is installed or enabled later.
    Waiting,
    /// The instance cannot make progress until the configuration changes.
    Error,
}

/// Why an enabled instance is not loading, or why its load ended in failure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DiagnosticKind {
    /// No installed instance provides the required contract.
    MissingProvider {
        /// The exact key that was required.
        required: ContractKey,
    },
    /// An installed provider exists but is not enabled.
    ProviderDisabled {
        /// The exact key that was required.
        required: ContractKey,
        /// The disabled provider.
        provider: InstanceId,
    },
    /// A provider exposes the required name with a different schema.
    SchemaMismatch {
        /// The exact key that was required.
        required: ContractKey,
        /// The key the provider exposes instead.
        provided: ContractKey,
        /// The provider exposing the other schema.
        provider: InstanceId,
    },
    /// The provider of a required contract is quarantined.
    ProviderQuarantined {
        /// The exact key that was required.
        required: ContractKey,
        /// The quarantined provider.
        provider: InstanceId,
    },
    /// A quarantined instance still holds a contract this instance provides.
    ContractQuarantined {
        /// The contract this instance provides.
        key: ContractKey,
        /// The quarantined instance holding it.
        owner: InstanceId,
    },
    /// The declarations form a cycle, so no member can load first.
    DependencyCycle {
        /// The cycle's instance path, including its closing instance.
        instances: Vec<InstanceId>,
    },
    /// A load completed but another instance held a provided contract, so the
    /// load failed instead of publishing.
    PublishConflict {
        /// The contested contract.
        key: ContractKey,
        /// The instance holding it.
        owner: InstanceId,
    },
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
            | Self::PublishConflict { .. } => Severity::Error,
        }
    }

    /// Describes the condition, naming every instance through `label`.
    ///
    /// The graph knows instances only by identity. The attachment supplies a
    /// label that names each instance's definition.
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
        }
    }
}

/// A planning diagnostic about one instance.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Diagnostic {
    /// The instance the diagnostic concerns.
    pub instance: InstanceId,
    /// What is blocking it.
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
