//! State-local contract identities, capability tokens, and declarations.
//!
//! Lua receives native [`PluginContractToken`] userdata. The registry copies
//! declarations into [`ValidatedDeclaration`] values.

use std::{
    cell::RefCell,
    collections::{BTreeMap, HashSet},
    error::Error,
    fmt,
    rc::{Rc, Weak},
};

use mlua::{UserData, Value};

use crate::plugin::graph::ContractKey;

/// The identity of a contract, excluding its schema version.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ContractName {
    authority: String,
    name: String,
}

impl ContractName {
    /// Creates an authority-qualified contract name. Neither component may
    /// contain a slash, which would make the qualified form ambiguous.
    pub fn new(
        authority: impl Into<String>,
        name: impl Into<String>,
    ) -> Result<Self, ContractError> {
        let authority = authority.into();
        let name = name.into();
        validate_name_component("authority", &authority)?;
        validate_name_component("name", &name)?;
        Ok(Self { authority, name })
    }

    /// Parses an authority-qualified name in `authority/name` form.
    pub fn from_qualified(qualified: impl Into<String>) -> Result<Self, ContractError> {
        let qualified = qualified.into();
        let Some((authority, name)) = qualified.split_once('/') else {
            return Err(ContractError::UnqualifiedName { name: qualified });
        };
        Self::new(authority, name)
    }

    #[must_use]
    pub fn qualified(&self) -> String {
        format!("{}/{}", self.authority, self.name)
    }
}

impl fmt::Display for ContractName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}/{}", self.authority, self.name)
    }
}

/// A native token that names one contract declaration.
///
/// The userdata registers no fields or methods, so Lua cannot read or forge one.
#[derive(Clone)]
pub struct PluginContractToken {
    registry: Weak<RegistryInner>,
    key: ContractKey,
}

impl fmt::Debug for PluginContractToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PluginContractToken")
            .field("key", &self.key)
            .finish_non_exhaustive()
    }
}

impl UserData for PluginContractToken {}

/// An immutable, copied declaration suitable for graph construction.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ValidatedDeclaration {
    bindings: BTreeMap<String, ContractKey>,
}

impl ValidatedDeclaration {
    pub fn iter(&self) -> impl Iterator<Item = (&str, &ContractKey)> {
        self.bindings.iter().map(|(name, key)| (name.as_str(), key))
    }
}

/// Errors raised while declaring, validating, or retiring contracts.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ContractError {
    /// A name component is empty, contains only whitespace, or contains a slash.
    InvalidNameComponent {
        component: &'static str,
        value: String,
    },
    /// A qualified name lacks its authority separator.
    UnqualifiedName { name: String },
    /// A schema number is zero or exceeds 32 bits.
    InvalidSchema { schema: u64 },
    /// The name and schema identity already exists in this epoch.
    DuplicateIdentity { key: ContractKey },
    /// A declaration value is not a table.
    DeclarationNotTable { actual: String },
    /// A declaration key is not a string.
    DeclarationKeyNotString { actual: String },
    /// A declaration key is a string that cannot be represented as UTF-8.
    DeclarationKeyNotUtf8,
    /// A declaration value is not native token userdata.
    DeclarationValueNotToken { key: String, actual: String },
    /// The token in a declaration field belongs to another registry.
    ForeignToken { key: String },
    /// The token in a declaration field belongs to an epoch retired by
    /// registry replacement.
    RetiredToken { key: String },
    /// Lua table iteration failed while copying a declaration.
    LuaIteration { message: String },
}

impl fmt::Display for ContractError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidNameComponent { component, value } => write!(
                formatter,
                "plugin contract: {component} name component '{value}' is not valid"
            ),
            Self::UnqualifiedName { name } => {
                write!(
                    formatter,
                    "plugin contract: '{name}' is not authority-qualified"
                )
            }
            Self::InvalidSchema { schema } => {
                write!(
                    formatter,
                    "plugin contract: schema {schema} is not a positive 32-bit integer"
                )
            }
            Self::DuplicateIdentity { key } => write!(
                formatter,
                "plugin contract: {} schema {} is already declared",
                key.name(),
                key.schema()
            ),
            Self::DeclarationNotTable { actual } => write!(
                formatter,
                "plugin contract: declaration must be a table, not a {actual}"
            ),
            Self::DeclarationKeyNotString { actual } => write!(
                formatter,
                "plugin contract: declaration keys must be strings, not {actual}"
            ),
            Self::DeclarationKeyNotUtf8 => {
                write!(
                    formatter,
                    "plugin contract: declaration keys must be UTF-8 strings"
                )
            }
            Self::DeclarationValueNotToken { key, actual } => write!(
                formatter,
                "plugin contract: declaration field '{key}' must contain a native contract token, not a {actual}"
            ),
            Self::ForeignToken { key } => write!(
                formatter,
                "plugin contract: the token in declaration field '{key}' is from another registry"
            ),
            Self::RetiredToken { key } => write!(
                formatter,
                "plugin contract: the token in declaration field '{key}' is from a retired epoch"
            ),
            Self::LuaIteration { message } => {
                write!(
                    formatter,
                    "plugin contract: declaration could not be read: {message}"
                )
            }
        }
    }
}

impl Error for ContractError {}

/// A registry shared by the runtimes in one state epoch. Cloning shares it.
#[derive(Clone)]
pub struct ContractRegistry {
    inner: Rc<RegistryInner>,
}

impl Default for ContractRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl ContractRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Rc::new(RegistryInner {
                contracts: RefCell::new(HashSet::new()),
            }),
        }
    }

    /// Declares a new name/schema identity and returns its native token. An
    /// identity may be declared once per registry.
    pub fn declare(
        &self,
        name: ContractName,
        schema: u64,
    ) -> Result<PluginContractToken, ContractError> {
        let schema = u32::try_from(schema)
            .ok()
            .filter(|schema| *schema != 0)
            .ok_or(ContractError::InvalidSchema { schema })?;
        let key = ContractKey::new(name.qualified(), schema);
        if !self.inner.contracts.borrow_mut().insert(key.clone()) {
            return Err(ContractError::DuplicateIdentity { key });
        }
        Ok(PluginContractToken {
            registry: Rc::downgrade(&self.inner),
            key,
        })
    }

    /// Validates and copies a Lua declaration record whose keys are strings and
    /// whose values are tokens declared in this registry.
    pub fn validate_declaration(
        &self,
        value: Value,
    ) -> Result<ValidatedDeclaration, ContractError> {
        let Value::Table(table) = value else {
            return Err(ContractError::DeclarationNotTable {
                actual: value.type_name().to_owned(),
            });
        };
        let mut bindings = BTreeMap::new();
        for pair in table.pairs::<Value, Value>() {
            let (key, value) = pair.map_err(|error| ContractError::LuaIteration {
                message: error.to_string(),
            })?;
            let key = match key {
                Value::String(key) => key
                    .to_str()
                    .map_err(|_| ContractError::DeclarationKeyNotUtf8)?
                    .to_owned(),
                other => {
                    return Err(ContractError::DeclarationKeyNotString {
                        actual: other.type_name().to_owned(),
                    });
                }
            };
            let contract = match value {
                Value::UserData(userdata) => {
                    let token = userdata.borrow::<PluginContractToken>().map_err(|_| {
                        ContractError::DeclarationValueNotToken {
                            key: key.clone(),
                            actual: String::from("userdata"),
                        }
                    })?;
                    check_token(&self.inner, &token, &key)?
                }
                other => {
                    return Err(ContractError::DeclarationValueNotToken {
                        key,
                        actual: other.type_name().to_owned(),
                    });
                }
            };
            bindings.insert(key, contract);
        }
        Ok(ValidatedDeclaration { bindings })
    }
}

struct RegistryInner {
    contracts: RefCell<HashSet<ContractKey>>,
}

fn check_token(
    registry: &Rc<RegistryInner>,
    token: &PluginContractToken,
    key: &str,
) -> Result<ContractKey, ContractError> {
    let Some(token_registry) = token.registry.upgrade() else {
        return Err(ContractError::RetiredToken {
            key: key.to_owned(),
        });
    };
    if !Rc::ptr_eq(registry, &token_registry) {
        return Err(ContractError::ForeignToken {
            key: key.to_owned(),
        });
    }
    Ok(token.key.clone())
}

fn validate_name_component(component: &'static str, value: &str) -> Result<(), ContractError> {
    if value.is_empty()
        || value.trim().is_empty()
        || value.contains('/')
        || value.chars().any(char::is_whitespace)
    {
        return Err(ContractError::InvalidNameComponent {
            component,
            value: value.to_owned(),
        });
    }
    Ok(())
}
