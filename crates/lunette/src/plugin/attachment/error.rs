//! Errors raised by the plugin attachment, and the plugin failures it reports.
//!
//! An operation raises an [`AttachmentError`] to its caller. A failure during
//! a lifecycle drain is a [`PluginFailure`], reported and recorded as the
//! instance's diagnostic rather than raised to whichever caller triggered it.

use std::{error::Error, fmt, sync::Arc};

use crate::plugin::{
    contracts::ContractError,
    graph::{GraphError, InstanceId},
};

/// An attachment operation was rejected or could not complete.
#[derive(Clone, Debug)]
pub enum AttachmentError {
    /// The attachment is not installed in this Lua state.
    NotInstalled,
    /// The runtime this handle belongs to has been dropped.
    RuntimeGone,
    /// The runtime this handle belongs to is closed or closing.
    RuntimeClosed,
    /// Shutdown was requested from inside a plugin callback.
    ShutdownInCallback,
    /// Shutdown could not advance the contract epoch.
    EpochExhausted,
    /// A definition from a retired epoch was installed.
    StaleDefinition { plugin: Arc<str> },
    /// A capability wrapper was not a table.
    WrapperNotTable {
        /// The Lua type that was supplied instead.
        found: &'static str,
    },
    /// A plugin context cannot perform an operation.
    Context {
        /// The operation that was attempted.
        operation: ContextOperation,
        /// Why the context cannot perform it.
        reason: ContextReason,
    },
    /// The lifecycle graph rejected a request.
    Graph {
        operation: &'static str,
        source: GraphError,
    },
    /// The contract registry rejected a declaration or binding.
    Contract(ContractError),
    /// A Lua value could not be created or read.
    Lua {
        operation: &'static str,
        source: mlua::Error,
    },
    /// A plugin failure that is raised rather than reported.
    Plugin(PluginFailure),
    /// A drain performed its action budget and stopped. The remaining work is
    /// derived from graph state, so the next drain resumes it.
    DrainBudget { budget: usize },
    /// Shutdown attempted every cleanup and some failed.
    Shutdown(Vec<AttachmentError>),
}

impl fmt::Display for AttachmentError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotInstalled => formatter.write_str("plugin attachment: not installed"),
            Self::RuntimeGone => formatter.write_str("plugin runtime: the runtime is gone"),
            Self::RuntimeClosed => formatter.write_str("plugin runtime: the runtime is closed"),
            Self::ShutdownInCallback => {
                formatter.write_str("plugin shutdown: cannot shut down during a plugin callback")
            }
            Self::EpochExhausted => {
                formatter.write_str("plugin shutdown: the contract epoch counter is exhausted")
            }
            Self::StaleDefinition { plugin } => write!(
                formatter,
                "plugin definition: {plugin} belongs to a retired contract epoch"
            ),
            Self::WrapperNotTable { found } => write!(
                formatter,
                "plugin contract: a wrapper must be a table, not a {found}"
            ),
            Self::Context { operation, reason } => {
                write!(formatter, "plugin {operation}: {reason}")
            }
            Self::Graph { operation, source } => write!(formatter, "plugin {operation}: {source}"),
            Self::Contract(source) => write!(formatter, "{source}"),
            Self::Lua { operation, source } => write!(formatter, "plugin {operation}: {source}"),
            Self::Plugin(failure) => write!(formatter, "{failure}"),
            Self::DrainBudget { budget } => write!(
                formatter,
                "plugin drain: stopped after {budget} actions; the next drain resumes the remaining work"
            ),
            Self::Shutdown(failures) => {
                write!(formatter, "plugin shutdown: {} failure(s)", failures.len())?;
                for failure in failures {
                    write!(formatter, "; {failure}")?;
                }
                Ok(())
            }
        }
    }
}

impl Error for AttachmentError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Graph { source, .. } => Some(source),
            Self::Contract(source) => Some(source),
            Self::Lua { source, .. } => Some(source),
            Self::Plugin(failure) => failure.source(),
            _ => None,
        }
    }
}

impl From<AttachmentError> for mlua::Error {
    fn from(error: AttachmentError) -> Self {
        match error {
            // A plugin's own error is raised unchanged, so its message and
            // traceback reach the caller as the plugin raised them.
            AttachmentError::Plugin(PluginFailure {
                cause: FailureCause::Callback(source),
                ..
            }) => source,
            other => Self::external(other),
        }
    }
}

/// An operation performed through a plugin context.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextOperation {
    /// `context:services()`.
    Services,
    /// `context:effect(...)`.
    Effect,
    /// `context:child(...)`.
    Child,
    /// `context:checkOwner(...)`.
    CheckOwner,
    /// Cleanup that requires the context's allocation.
    Cleanup,
}

impl fmt::Display for ContextOperation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Services => "services",
            Self::Effect => "effect",
            Self::Child => "child",
            Self::CheckOwner => "checkOwner",
            Self::Cleanup => "cleanup",
        })
    }
}

/// Why a context cannot perform an operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextReason {
    /// The runtime was dropped.
    RuntimeGone,
    /// The instance was removed from its runtime.
    InstanceGone,
    /// The context's activation has ended or been replaced.
    Stale,
    /// The context is running cleanup and may not acquire.
    CleanupOnly,
    /// The activation was cancelled before it could publish or acquire.
    Cancelled,
    /// A bound provider is no longer published at the bound generation.
    ProviderStale,
    /// A declared field has no matching contract binding.
    FieldMissing,
    /// The caller belongs to another runtime.
    ForeignRuntime,
    /// The owner value is not a live plugin context.
    NotAContext,
    /// The caller is not loading or active.
    CallerInactive,
    /// The caller does not depend on this provider's current generation.
    NotOwner,
}

impl fmt::Display for ContextReason {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::RuntimeGone => "the runtime is gone",
            Self::InstanceGone => "the instance is gone",
            Self::Stale => "the context is stale",
            Self::CleanupOnly => "the activation is cleanup-only",
            Self::Cancelled => "the activation was cancelled",
            Self::ProviderStale => "a provider is no longer published at the bound generation",
            Self::FieldMissing => "a declared field has no contract binding",
            Self::ForeignRuntime => "the caller belongs to another runtime",
            Self::NotAContext => "the owner is not a plugin context",
            Self::CallerInactive => "the caller is not loading or active",
            Self::NotOwner => "the caller does not depend on this provider",
        })
    }
}

/// The lifecycle phase a plugin failure happened in.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FailurePhase {
    /// The initializer, or publication of its result.
    Load,
    /// An inverse run because a load failed or was cancelled.
    Rollback,
    /// An inverse run because an activation unloaded.
    Cleanup,
    /// An inverse run because its effect was disposed.
    Disposal,
    /// The graph cannot load the instance.
    Wiring,
}

impl fmt::Display for FailurePhase {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Load => "plugin load",
            Self::Rollback => "plugin rollback",
            Self::Cleanup => "plugin cleanup",
            Self::Disposal => "plugin effect disposal",
            Self::Wiring => "plugin wiring",
        })
    }
}

/// An instance named by its definition.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PluginLabel {
    pub name: Arc<str>,
    pub instance: InstanceId,
}

impl fmt::Display for PluginLabel {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{} ({})", self.name, self.instance)
    }
}

/// What failed.
#[derive(Clone, Debug)]
pub enum FailureCause {
    /// A plugin callback raised, or Lua could not create a value to call it
    /// with.
    Callback(mlua::Error),
    /// The initializer returned a malformed provided record.
    Provision(ProvisionError),
    /// The definition's callbacks were released with its epoch.
    InitializerCleared,
    /// The attachment's own record for the instance is missing.
    MissingRecord,
    /// The graph cannot load the instance, as described.
    Blocked(String),
}

impl fmt::Display for FailureCause {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Callback(source) => write!(formatter, "{source}"),
            Self::Provision(source) => write!(formatter, "{source}"),
            Self::InitializerCleared => {
                formatter.write_str("the definition's callbacks were released with its epoch")
            }
            Self::MissingRecord => formatter.write_str("the attachment has no record of it"),
            Self::Blocked(description) => formatter.write_str(description),
        }
    }
}

/// A failure inside a plugin's lifecycle, attributed to the instance it belongs to.
#[derive(Clone, Debug)]
pub struct PluginFailure {
    pub phase: FailurePhase,
    pub plugin: PluginLabel,
    pub cause: FailureCause,
}

impl PluginFailure {
    /// The boundary a report names, leading its message.
    #[must_use]
    pub fn context(&self) -> String {
        format!("{}: {}", self.phase, self.plugin)
    }

    /// The error a report carries. A callback's own error keeps its traceback.
    #[must_use]
    pub fn lua_error(&self) -> mlua::Error {
        match &self.cause {
            FailureCause::Callback(source) => source.clone(),
            other => mlua::Error::runtime(other.to_string()),
        }
    }
}

impl fmt::Display for PluginFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.context(), self.cause)
    }
}

impl Error for PluginFailure {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match &self.cause {
            FailureCause::Callback(source) => Some(source),
            FailureCause::Provision(source) => Some(source),
            FailureCause::InitializerCleared
            | FailureCause::MissingRecord
            | FailureCause::Blocked(_) => None,
        }
    }
}

/// An initializer returned a provided record that does not match its declaration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProvisionError {
    /// The initializer returned something other than a table.
    NotATable,
    /// A key of the record is not a string.
    KeyNotString,
    /// A field of the record is nil.
    NilField(String),
    /// A field of the record is not declared.
    UnexpectedField(String),
    /// A declared field is absent.
    MissingField(String),
    /// The record could not be read.
    Unreadable(String),
}

impl fmt::Display for ProvisionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotATable => formatter.write_str("the initializer must return a table"),
            Self::KeyNotString => formatter.write_str("provided record keys must be strings"),
            Self::NilField(field) => write!(formatter, "provided field '{field}' is nil"),
            Self::UnexpectedField(field) => {
                write!(formatter, "provided record has unexpected field '{field}'")
            }
            Self::MissingField(field) => {
                write!(formatter, "provided record is missing field '{field}'")
            }
            Self::Unreadable(message) => {
                write!(formatter, "provided record could not be read: {message}")
            }
        }
    }
}

impl Error for ProvisionError {}
