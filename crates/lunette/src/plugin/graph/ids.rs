//! Identifiers and contract bindings owned by the lifecycle graph.

use std::fmt;

/// The identity of an installed plugin instance.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct InstanceId(u64);

impl InstanceId {
    pub(crate) const fn from_raw(value: u64) -> Self {
        Self(value)
    }
}

impl fmt::Display for InstanceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "instance {}", self.0)
    }
}

/// The identity of one load attempt. It is never reused, including after a
/// failed load or a clean unload.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ActivationId(u64);

impl ActivationId {
    pub(crate) const fn from_raw(value: u64) -> Self {
        Self(value)
    }
}

impl fmt::Display for ActivationId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "activation {}", self.0)
    }
}

/// The generation of a published provider attachment. A generation changes
/// whenever the provider is loaded again, even when it has the same instance
/// identity as before.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ProviderGeneration(u64);

impl ProviderGeneration {
    pub(crate) const fn from_raw(value: u64) -> Self {
        Self(value)
    }
}

impl fmt::Display for ProviderGeneration {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "generation {}", self.0)
    }
}

/// A contract name together with the exact schema it implements or requires.
/// Reservation and binding compare the complete key.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ContractKey {
    name: String,
    schema: u32,
}

impl ContractKey {
    #[must_use]
    pub fn new(name: impl Into<String>, schema: u32) -> Self {
        Self {
            name: name.into(),
            schema,
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub const fn schema(&self) -> u32 {
        self.schema
    }
}

impl fmt::Display for ContractKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}@{}", self.name, self.schema)
    }
}

/// A requirement bound to the exact published generation that satisfies it.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Binding {
    pub contract: ContractKey,
    pub provider: InstanceId,
    /// The provider generation observed during allocation.
    pub generation: ProviderGeneration,
}
