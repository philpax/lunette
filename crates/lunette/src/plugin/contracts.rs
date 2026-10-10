//! State-local contract identities, capability tokens, and declarations.

use std::{
    cell::RefCell,
    collections::{BTreeMap, HashSet},
    error::Error,
    fmt,
    rc::{Rc, Weak},
};

use mlua::{UserData, Value};

use crate::plugin::graph::ContractKey;

/// A native token that names one contract declaration. It has no fields or methods, so Lua cannot read or forge one.
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

/// One field of a validated declaration and the contract its token names.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeclarationField {
    pub field: String,
    pub key: ContractKey,
}

/// Errors raised while declaring, validating, or retiring contracts.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ContractError {
    /// A name component is empty, contains only whitespace, or contains a slash.
    InvalidNameComponent {
        component: &'static str,
        value: String,
    },
    UnqualifiedName {
        name: String,
    },
    /// A schema number is zero or exceeds 32 bits.
    InvalidSchema {
        schema: u64,
    },
    /// The name and schema identity already exists in this epoch.
    DuplicateIdentity {
        key: ContractKey,
    },
    DeclarationNotTable {
        actual: String,
    },
    DeclarationKeyNotString {
        actual: String,
    },
    /// A declaration key is a string that cannot be represented as UTF-8.
    DeclarationKeyNotUtf8,
    DeclarationValueNotToken {
        key: String,
        actual: String,
    },
    /// The token in a declaration field belongs to another registry.
    ForeignToken {
        key: String,
    },
    /// The token belongs to an epoch that registry replacement retired.
    RetiredToken {
        key: String,
    },
    LuaIteration {
        message: String,
    },
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

    /// Declares an `authority/name` identity, which may be declared once per registry.
    /// A slash in either component would make the qualified form ambiguous.
    pub fn declare(&self, name: &str, schema: u64) -> Result<PluginContractToken, ContractError> {
        let Some((authority, local)) = name.split_once('/') else {
            return Err(ContractError::UnqualifiedName {
                name: name.to_owned(),
            });
        };
        validate_name_component("authority", authority)?;
        validate_name_component("name", local)?;
        let schema = u32::try_from(schema)
            .ok()
            .filter(|schema| *schema != 0)
            .ok_or(ContractError::InvalidSchema { schema })?;
        let key = ContractKey::new(name, schema);
        if !self.inner.contracts.borrow_mut().insert(key.clone()) {
            return Err(ContractError::DuplicateIdentity { key });
        }
        Ok(PluginContractToken {
            registry: Rc::downgrade(&self.inner),
            key,
        })
    }

    /// Copies a Lua declaration whose keys are strings and whose values are tokens from this registry.
    /// The fields are sorted by name.
    pub fn validate_declaration(
        &self,
        value: Value,
    ) -> Result<Vec<DeclarationField>, ContractError> {
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
        Ok(bindings
            .into_iter()
            .map(|(field, key)| DeclarationField { field, key })
            .collect())
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
