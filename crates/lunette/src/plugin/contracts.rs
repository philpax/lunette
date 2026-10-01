//! State-local contract identities, native capability tokens, and declarations.
//!
//! Lua sees only native [`ContractToken`] userdata, and a declaration is
//! copied into a [`ValidatedDeclaration`] so the graph never retains a Lua table.

use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, HashMap},
    error::Error,
    ffi::c_void,
    fmt,
    num::NonZeroU64,
    rc::{Rc, Weak},
};

use mlua::{Lua, Table, UserData, Value};

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
    pub fn authority(&self) -> &str {
        &self.authority
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
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

/// A positive contract schema number.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ContractSchema(NonZeroU64);

impl ContractSchema {
    /// Returns a schema number, or `None` for zero.
    #[must_use]
    pub fn new(value: u64) -> Option<Self> {
        NonZeroU64::new(value).map(Self)
    }

    #[must_use]
    pub fn get(self) -> u64 {
        self.0.get()
    }
}

/// An opaque identifier for a declared contract, meaningful only within the
/// registry epoch that produced it.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ContractId {
    epoch: u64,
    ordinal: u64,
}

impl ContractId {
    #[must_use]
    pub fn epoch(self) -> u64 {
        self.epoch
    }

    #[must_use]
    pub fn ordinal(self) -> u64 {
        self.ordinal
    }
}

/// A native token that names one contract declaration.
///
/// The userdata registers no fields or methods, so Lua cannot read or forge one.
#[derive(Clone)]
pub struct PluginContractToken {
    registry: Weak<RegistryInner>,
    epoch: u64,
    id: ContractId,
    identity: ContractIdentity,
}

pub type ContractToken = PluginContractToken;

impl fmt::Debug for PluginContractToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ContractToken")
            .field("epoch", &self.epoch)
            .field("id", &self.id)
            .finish_non_exhaustive()
    }
}

impl UserData for PluginContractToken {}

/// An immutable, copied declaration suitable for graph construction.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ValidatedDeclaration {
    bindings: BTreeMap<String, ContractId>,
}

impl ValidatedDeclaration {
    /// Returns the ID bound to a declaration field.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<ContractId> {
        self.bindings.get(name).copied()
    }

    /// Iterates copied declaration fields in lexical order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, ContractId)> {
        self.bindings.iter().map(|(name, id)| (name.as_str(), *id))
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.bindings.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.bindings.is_empty()
    }
}

/// Errors raised while declaring, validating, or retiring contracts.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ContractError {
    /// A name component was empty, whitespace-only, or contained a slash.
    InvalidNameComponent {
        component: &'static str,
        value: String,
    },
    /// A qualified name was missing its authority separator.
    UnqualifiedName { name: String },
    /// A schema number was zero.
    InvalidSchema { schema: u64 },
    /// The exact name/schema identity was already declared in this epoch.
    DuplicateIdentity {
        name: ContractName,
        schema: ContractSchema,
    },
    /// The registry could not allocate another ordinal or epoch.
    RegistryExhausted,
    /// The value passed as a declaration was not a table.
    DeclarationNotTable { actual: String },
    /// A declaration key was not a string.
    DeclarationKeyNotString { actual: String },
    /// A declaration key was a string that cannot be represented as UTF-8.
    DeclarationKeyNotUtf8,
    /// A declaration value was not native token userdata.
    DeclarationValueNotToken { key: String, actual: String },
    /// The token belongs to another registry.
    ForeignToken { key: String },
    /// The token was created in an epoch that has been retired.
    RetiredToken { key: String },
    /// The capability wrapper was bound in an epoch that has been retired.
    RetiredWrapper { key: String },
    /// The token has the registry identity but not a currently registered identity.
    UnknownToken { key: String },
    /// A capability wrapper was mutable when native code tried to bind it.
    WrapperNotFrozen,
    /// The token already has a capability wrapper.
    TokenAlreadyBound,
    /// The capability wrapper is already bound to another token.
    WrapperAlreadyBound,
    /// A table was supplied where a previously bound capability wrapper was required.
    UnboundWrapper { key: String },
    /// Iterating a Lua table failed before its declaration could be copied.
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
                    "plugin contract: schema {schema} is not positive"
                )
            }
            Self::DuplicateIdentity { name, schema } => write!(
                formatter,
                "plugin contract: {name} schema {} is already declared",
                schema.get()
            ),
            Self::RegistryExhausted => write!(
                formatter,
                "plugin contract: registry identity space is exhausted"
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
                "plugin contract: declaration field '{key}' contains a token from another registry"
            ),
            Self::RetiredToken { key } => write!(
                formatter,
                "plugin contract: declaration field '{key}' contains a token from a retired epoch"
            ),
            Self::RetiredWrapper { key } => write!(
                formatter,
                "plugin contract: declaration field '{key}' contains a capability from a retired contract epoch"
            ),
            Self::UnknownToken { key } => write!(
                formatter,
                "plugin contract: declaration field '{key}' contains an unknown contract token"
            ),
            Self::WrapperNotFrozen => write!(
                formatter,
                "plugin contract: a capability wrapper must be frozen before native binding"
            ),
            Self::TokenAlreadyBound => write!(
                formatter,
                "plugin contract: a contract token can be bound to only one capability wrapper"
            ),
            Self::WrapperAlreadyBound => write!(
                formatter,
                "plugin contract: a capability wrapper is already bound to another contract token"
            ),
            Self::UnboundWrapper { key } => write!(
                formatter,
                "plugin contract: declaration field '{key}' contains an unbound capability wrapper"
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
                epoch: Cell::new(1),
                next_ordinal: Cell::new(1),
                identities: RefCell::new(HashMap::new()),
                contracts: RefCell::new(HashMap::new()),
                bindings: RefCell::new(HashMap::new()),
            }),
        }
    }

    #[must_use]
    pub fn epoch(&self) -> u64 {
        self.inner.epoch.get()
    }

    /// Declares a new name/schema identity and returns its native token. An
    /// identity may be declared once per epoch.
    pub fn declare(&self, name: ContractName, schema: u64) -> Result<ContractToken, ContractError> {
        let schema = ContractSchema::new(schema).ok_or(ContractError::InvalidSchema { schema })?;
        let identity = ContractIdentity { name, schema };
        if self.inner.identities.borrow().contains_key(&identity) {
            return Err(ContractError::DuplicateIdentity {
                name: identity.name,
                schema: identity.schema,
            });
        }

        let ordinal = self.inner.next_ordinal.get();
        let Some(next_ordinal) = ordinal.checked_add(1) else {
            return Err(ContractError::RegistryExhausted);
        };
        let id = ContractId {
            epoch: self.epoch(),
            ordinal,
        };
        self.inner.next_ordinal.set(next_ordinal);
        self.inner
            .identities
            .borrow_mut()
            .insert(identity.clone(), id);
        self.inner
            .contracts
            .borrow_mut()
            .insert(id, identity.clone());
        Ok(ContractToken {
            registry: Rc::downgrade(&self.inner),
            epoch: self.epoch(),
            id,
            identity,
        })
    }

    /// Retires all tokens and declarations in the current epoch. The epoch
    /// number never wraps, so a stale epoch cannot alias a live one.
    pub fn retire_epoch(&self) -> Result<(), ContractError> {
        let epoch = self.epoch();
        let Some(next_epoch) = epoch.checked_add(1) else {
            return Err(ContractError::RegistryExhausted);
        };
        self.inner.epoch.set(next_epoch);
        self.inner.next_ordinal.set(1);
        self.inner.identities.borrow_mut().clear();
        self.inner.contracts.borrow_mut().clear();
        Ok(())
    }

    /// Verifies a native token and returns its typed ID.
    pub fn validate_token(&self, token: &ContractToken) -> Result<ContractId, ContractError> {
        let Some(token_registry) = token.registry.upgrade() else {
            return Err(ContractError::RetiredToken {
                key: String::from("<token>"),
            });
        };
        if !Rc::ptr_eq(&self.inner, &token_registry) {
            return Err(ContractError::ForeignToken {
                key: String::from("<token>"),
            });
        }
        if token.epoch != self.epoch() {
            return Err(ContractError::RetiredToken {
                key: String::from("<token>"),
            });
        }
        let contracts = self.inner.contracts.borrow();
        let Some(identity) = contracts.get(&token.id) else {
            return Err(ContractError::UnknownToken {
                key: String::from("<token>"),
            });
        };
        if identity != &token.identity {
            return Err(ContractError::UnknownToken {
                key: String::from("<token>"),
            });
        }
        Ok(token.id)
    }

    /// Binds a frozen Lua capability wrapper to one native contract token.
    ///
    /// Binding is one-to-one in both directions. The registry retains the table
    /// so its identity cannot be recycled after Lua garbage collection.
    pub fn bind_token(&self, token: &ContractToken, wrapper: &Table) -> Result<(), ContractError> {
        let id = self.validate_token(token)?;
        if !wrapper.is_readonly() {
            return Err(ContractError::WrapperNotFrozen);
        }
        let pointer = wrapper.to_pointer();
        let mut bindings = self.inner.bindings.borrow_mut();
        if bindings
            .values()
            .any(|binding| binding.token == id && binding.epoch == self.epoch())
        {
            return Err(ContractError::TokenAlreadyBound);
        }
        if bindings.contains_key(&pointer) {
            return Err(ContractError::WrapperAlreadyBound);
        }
        bindings.insert(
            pointer,
            WrapperBinding {
                epoch: self.epoch(),
                token: id,
                table: wrapper.clone(),
            },
        );
        Ok(())
    }

    /// Returns every capability wrapper bound to this registry, in any epoch, so
    /// a wrapper from a retired epoch can be named as retired rather than unbound.
    #[must_use]
    pub fn bound_wrappers(&self) -> Vec<Table> {
        self.inner
            .bindings
            .borrow()
            .values()
            .map(|binding| binding.table.clone())
            .collect()
    }

    /// Binds a frozen capability wrapper supplied as a Lua value.
    pub fn bind_token_value(
        &self,
        token: &ContractToken,
        wrapper: Value,
    ) -> Result<(), ContractError> {
        let Value::Table(wrapper) = wrapper else {
            return Err(ContractError::DeclarationNotTable {
                actual: wrapper.type_name().to_owned(),
            });
        };
        self.bind_token(token, &wrapper)
    }

    /// Validates and copies a Lua declaration record whose keys are strings and
    /// whose values are tokens or wrappers bound in the active epoch.
    pub fn validate_declaration(
        &self,
        value: Value,
    ) -> Result<ValidatedDeclaration, ContractError> {
        let Value::Table(table) = value else {
            return Err(ContractError::DeclarationNotTable {
                actual: value.type_name().to_owned(),
            });
        };
        self.validate_table(&table)
    }

    /// Validates and copies a Lua declaration table.
    pub fn validate_table(&self, table: &Table) -> Result<ValidatedDeclaration, ContractError> {
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
            let id = match value {
                Value::UserData(userdata) => {
                    let token = userdata.borrow::<ContractToken>().map_err(|_| {
                        ContractError::DeclarationValueNotToken {
                            key: key.clone(),
                            actual: String::from("userdata"),
                        }
                    })?;
                    self.validate_token_for_key(&token, &key)?
                }
                Value::Table(wrapper) => self.validate_wrapper_for_key(&wrapper, &key)?,
                other => {
                    return Err(ContractError::DeclarationValueNotToken {
                        key,
                        actual: other.type_name().to_owned(),
                    });
                }
            };
            bindings.insert(key, id);
        }
        Ok(ValidatedDeclaration { bindings })
    }

    /// Creates Lua userdata for a token, refusing one from a retired epoch.
    pub fn token_value(&self, lua: &Lua, token: &ContractToken) -> Result<Value, ContractError> {
        self.validate_token(token)?;
        lua.create_userdata(token.clone())
            .map(Value::UserData)
            .map_err(|error| ContractError::LuaIteration {
                message: error.to_string(),
            })
    }

    fn validate_token_for_key(
        &self,
        token: &ContractToken,
        key: &str,
    ) -> Result<ContractId, ContractError> {
        self.validate_token(token).map_err(|error| match error {
            ContractError::ForeignToken { .. } => ContractError::ForeignToken {
                key: key.to_owned(),
            },
            ContractError::RetiredToken { .. } => ContractError::RetiredToken {
                key: key.to_owned(),
            },
            ContractError::UnknownToken { .. } => ContractError::UnknownToken {
                key: key.to_owned(),
            },
            other => other,
        })
    }

    fn validate_wrapper_for_key(
        &self,
        wrapper: &Table,
        key: &str,
    ) -> Result<ContractId, ContractError> {
        let bindings = self.inner.bindings.borrow();
        let Some(binding) = bindings.get(&wrapper.to_pointer()) else {
            return Err(ContractError::UnboundWrapper {
                key: key.to_owned(),
            });
        };
        let id = binding.token;
        if binding.table.to_pointer() != wrapper.to_pointer() {
            return Err(ContractError::UnboundWrapper {
                key: key.to_owned(),
            });
        }
        if !wrapper.is_readonly() {
            return Err(ContractError::WrapperNotFrozen);
        }
        if binding.epoch != self.epoch() {
            return Err(ContractError::RetiredWrapper {
                key: key.to_owned(),
            });
        }
        let contracts = self.inner.contracts.borrow();
        if contracts.contains_key(&id) && id.epoch() == self.epoch() {
            Ok(id)
        } else {
            Err(ContractError::RetiredWrapper {
                key: key.to_owned(),
            })
        }
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct ContractIdentity {
    name: ContractName,
    schema: ContractSchema,
}

struct RegistryInner {
    epoch: Cell<u64>,
    next_ordinal: Cell<u64>,
    identities: RefCell<HashMap<ContractIdentity, ContractId>>,
    contracts: RefCell<HashMap<ContractId, ContractIdentity>>,
    bindings: RefCell<HashMap<*const c_void, WrapperBinding>>,
}

struct WrapperBinding {
    epoch: u64,
    token: ContractId,
    table: Table,
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
