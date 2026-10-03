//! State-local contract identities, native capability tokens, and declarations.
//!
//! Lua sees only native [`ContractToken`] userdata, and a declaration is
//! copied into a [`ValidatedDeclaration`] so the graph never retains a Lua table.

use std::{
    cell::RefCell,
    collections::{BTreeMap, HashMap, HashSet},
    error::Error,
    ffi::c_void,
    fmt,
    rc::{Rc, Weak},
};

use mlua::{Lua, Table, UserData, Value};

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

/// A native token that names one contract declaration.
///
/// The userdata registers no fields or methods, so Lua cannot read or forge one.
#[derive(Clone)]
pub struct PluginContractToken {
    registry: Weak<RegistryInner>,
    key: ContractKey,
}

pub type ContractToken = PluginContractToken;

impl fmt::Debug for PluginContractToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ContractToken")
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
    /// Returns the contract bound to a declaration field.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<&ContractKey> {
        self.bindings.get(name)
    }

    /// Iterates copied declaration fields in lexical order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &ContractKey)> {
        self.bindings.iter().map(|(name, key)| (name.as_str(), key))
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
    /// A schema number was zero or does not fit in 32 bits.
    InvalidSchema { schema: u64 },
    /// The exact name/schema identity was already declared in this epoch.
    DuplicateIdentity { key: ContractKey },
    /// The value passed as a declaration was not a table.
    DeclarationNotTable { actual: String },
    /// A declaration key was not a string.
    DeclarationKeyNotString { actual: String },
    /// A declaration key was a string that cannot be represented as UTF-8.
    DeclarationKeyNotUtf8,
    /// A declaration value was not native token userdata.
    DeclarationValueNotToken { key: String, actual: String },
    /// The token belongs to another registry.
    ForeignToken { site: TokenSite },
    /// The token's registry has been replaced, which retires its epoch.
    RetiredToken { site: TokenSite },
    /// The capability wrapper was bound in an epoch that has been retired.
    RetiredWrapper { key: String },
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
            Self::ForeignToken { site } => write!(
                formatter,
                "plugin contract: {site} is from another registry"
            ),
            Self::RetiredToken { site } => {
                write!(formatter, "plugin contract: {site} is from a retired epoch")
            }
            Self::RetiredWrapper { key } => write!(
                formatter,
                "plugin contract: declaration field '{key}' contains a capability from a retired contract epoch"
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

/// Where a contract token was presented, which a token error names.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TokenSite {
    /// The token is the value of a declaration field.
    Field(String),
    /// The token stands alone, as it does when it is bound to a capability
    /// wrapper, and is named by the contract it was declared for.
    Contract(ContractKey),
}

impl fmt::Display for TokenSite {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Field(key) => write!(formatter, "the token in declaration field '{key}'"),
            Self::Contract(key) => write!(formatter, "the token for {key}"),
        }
    }
}

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
                bindings: RefCell::new(HashMap::new()),
            }),
        }
    }

    /// Declares a new name/schema identity and returns its native token. An
    /// identity may be declared once per registry.
    pub fn declare(&self, name: ContractName, schema: u64) -> Result<ContractToken, ContractError> {
        let schema = u32::try_from(schema)
            .ok()
            .filter(|schema| *schema != 0)
            .ok_or(ContractError::InvalidSchema { schema })?;
        let key = ContractKey::new(name.qualified(), schema);
        if !self.inner.contracts.borrow_mut().insert(key.clone()) {
            return Err(ContractError::DuplicateIdentity { key });
        }
        Ok(ContractToken {
            registry: Rc::downgrade(&self.inner),
            key,
        })
    }

    /// Verifies a native token and returns its contract. An error names the
    /// token by the contract it was declared for.
    pub fn validate_token(&self, token: &ContractToken) -> Result<ContractKey, ContractError> {
        self.check_token(token, || TokenSite::Contract(token.key.clone()))
    }

    fn check_token(
        &self,
        token: &ContractToken,
        site: impl FnOnce() -> TokenSite,
    ) -> Result<ContractKey, ContractError> {
        let Some(token_registry) = token.registry.upgrade() else {
            return Err(ContractError::RetiredToken { site: site() });
        };
        if !Rc::ptr_eq(&self.inner, &token_registry) {
            return Err(ContractError::ForeignToken { site: site() });
        }
        Ok(token.key.clone())
    }

    /// Binds a frozen Lua capability wrapper to one native contract token.
    ///
    /// Binding is one-to-one in both directions. The registry retains the table
    /// so its identity cannot be recycled after Lua garbage collection.
    pub fn bind_token(&self, token: &ContractToken, wrapper: &Table) -> Result<(), ContractError> {
        let key = self.validate_token(token)?;
        if !wrapper.is_readonly() {
            return Err(ContractError::WrapperNotFrozen);
        }
        let pointer = wrapper.to_pointer();
        let mut bindings = self.inner.bindings.borrow_mut();
        if bindings.values().any(|binding| binding.token == key) {
            return Err(ContractError::TokenAlreadyBound);
        }
        if bindings.contains_key(&pointer) {
            return Err(ContractError::WrapperAlreadyBound);
        }
        bindings.insert(
            pointer,
            WrapperBinding {
                token: key,
                table: wrapper.clone(),
            },
        );
        Ok(())
    }

    /// Returns every capability wrapper bound to this registry, so the host can
    /// name one as retired rather than unbound once the registry is replaced.
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
    /// whose values are tokens or wrappers bound in this registry.
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
            let contract = match value {
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
            bindings.insert(key, contract);
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
    ) -> Result<ContractKey, ContractError> {
        self.check_token(token, || TokenSite::Field(key.to_owned()))
    }

    fn validate_wrapper_for_key(
        &self,
        wrapper: &Table,
        key: &str,
    ) -> Result<ContractKey, ContractError> {
        let bindings = self.inner.bindings.borrow();
        let Some(binding) = bindings.get(&wrapper.to_pointer()) else {
            return Err(ContractError::UnboundWrapper {
                key: key.to_owned(),
            });
        };
        if !wrapper.is_readonly() {
            return Err(ContractError::WrapperNotFrozen);
        }
        Ok(binding.token.clone())
    }
}

struct RegistryInner {
    contracts: RefCell<HashSet<ContractKey>>,
    bindings: RefCell<HashMap<*const c_void, WrapperBinding>>,
}

struct WrapperBinding {
    token: ContractKey,
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
