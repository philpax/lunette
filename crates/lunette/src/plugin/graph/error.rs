//! Structured diagnostics emitted while installing and advancing the graph.

use std::{error::Error, fmt};

use crate::plugin::graph::{ContractKey, InstanceId};

/// A graph operation failed before it changed the graph.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum GraphError {
    /// A provided contract name is already reserved by another instance.
    ContractConflict {
        /// The name that could not be reserved.
        name: String,
        /// The instance that already owns the reservation.
        owner: InstanceId,
        /// The attempted key, including its schema.
        attempted: ContractKey,
    },
    /// A descriptor provides the same contract name more than once.
    DuplicateProvided {
        /// The duplicated contract name.
        name: String,
    },
    /// A required contract has no installed provider.
    MissingDependency {
        /// The instance with the unsatisfied requirement.
        instance: InstanceId,
        /// The exact key that was required.
        required: ContractKey,
    },
    /// A required contract exists, but its schema is not exact.
    SchemaMismatch {
        /// The instance with the unsatisfied requirement.
        instance: InstanceId,
        /// The exact key that was required.
        required: ContractKey,
        /// The installed provider's key.
        provided: ContractKey,
    },
    /// Parent relationships cannot contain a cycle.
    ParentCycle {
        /// The attempted child instance.
        child: InstanceId,
        /// The parent that would close the cycle.
        parent: InstanceId,
    },
    /// An operation references an unknown instance.
    UnknownInstance(InstanceId),
    /// The bounded intent queue rejected an additional request.
    QueueExhausted,
    /// The graph is shutting down and cannot accept a new installation.
    ShuttingDown,
    /// A dependency cycle prevents a deterministic load order.
    DependencyCycle {
        /// The cycle's instance path, including its closing instance.
        instances: Vec<InstanceId>,
    },
    /// An identifier counter cannot allocate another identity.
    IdExhausted,
    /// An attachment report does not match the current action.
    StaleAction,
    /// An attachment report uses the wrong lifecycle state.
    InvalidAction,
}

impl fmt::Display for GraphError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ContractConflict {
                name,
                owner,
                attempted,
            } => write!(
                formatter,
                "plugin graph: contract name {name:?} is reserved by {owner}, cannot reserve {attempted}"
            ),
            Self::DuplicateProvided { name } => {
                write!(
                    formatter,
                    "plugin graph: descriptor provides {name:?} more than once"
                )
            }
            Self::MissingDependency { instance, required } => write!(
                formatter,
                "plugin graph: {instance} requires missing contract {required}"
            ),
            Self::SchemaMismatch {
                instance,
                required,
                provided,
            } => write!(
                formatter,
                "plugin graph: {instance} requires {required}, provider exposes {provided}"
            ),
            Self::ParentCycle { child, parent } => write!(
                formatter,
                "plugin graph: parent assignment for {child} through {parent} forms a cycle"
            ),
            Self::UnknownInstance(instance) => {
                write!(formatter, "plugin graph: unknown {instance}")
            }
            Self::QueueExhausted => write!(formatter, "plugin graph: intent queue is exhausted"),
            Self::ShuttingDown => write!(formatter, "plugin graph: graph is shutting down"),
            Self::DependencyCycle { instances } => write!(
                formatter,
                "plugin graph: dependency cycle through {}",
                instances
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(" -> ")
            ),
            Self::IdExhausted => write!(formatter, "plugin graph: identifier space is exhausted"),
            Self::StaleAction => write!(formatter, "plugin graph: action report is stale"),
            Self::InvalidAction => write!(formatter, "plugin graph: action report is invalid"),
        }
    }
}

impl Error for GraphError {}
