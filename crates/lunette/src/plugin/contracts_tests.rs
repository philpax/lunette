use std::error::Error;

use mlua::{Lua, Value};

use super::{
    contracts::{ContractError, ContractName, ContractRegistry, PluginContractToken},
    graph::ContractKey,
};

#[test]
fn a_contract_identity_is_its_name_and_schema_within_one_registry() -> Result<(), Box<dyn Error>> {
    let lua = Lua::new();
    let stale = ContractRegistry::new().declare(contract_name("example", "clock"), 1)?;
    let registry = ContractRegistry::new();
    let first = registry.declare(contract_name("example", "clock"), 1)?;
    let other_schema = registry.declare(contract_name("example", "clock"), 2)?;
    let other_authority = registry.declare(contract_name("other", "clock"), 1)?;
    let first_key = token_key(&lua, &registry, &first)?;
    assert_ne!(first_key, token_key(&lua, &registry, &other_schema)?);
    assert_ne!(first_key, token_key(&lua, &registry, &other_authority)?);
    assert!(matches!(
        registry.declare(contract_name("example", "clock"), 1),
        Err(ContractError::DuplicateIdentity { .. })
    ));
    for schema in [0, u64::from(u32::MAX) + 1] {
        assert_eq!(
            registry
                .declare(contract_name("example", "clock"), schema)
                .err(),
            Some(ContractError::InvalidSchema { schema })
        );
    }
    assert_eq!(
        token_key(&lua, &registry, &stale)
            .err()
            .map(|error| error.to_string()),
        Some(String::from(
            "plugin contract: the token in declaration field 'field' is from a retired epoch"
        ))
    );
    let foreign = ContractRegistry::new().declare(contract_name("example", "clock"), 1)?;
    assert!(token_key(&lua, &registry, &foreign).is_err());
    Ok(())
}

#[test]
fn a_declaration_is_a_detached_table_of_named_tokens() -> Result<(), Box<dyn Error>> {
    let lua = Lua::new();
    let registry = ContractRegistry::new();
    let token = registry.declare(contract_name("example", "clock"), 1)?;
    assert!(matches!(
        registry.validate_declaration(Value::Boolean(true)),
        Err(ContractError::DeclarationNotTable { .. })
    ));
    let numeric_key = lua.create_table()?;
    numeric_key.set(1, token.clone())?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(numeric_key)),
        Err(ContractError::DeclarationKeyNotString { .. })
    ));
    let non_token = lua.create_table()?;
    non_token.set("clock", true)?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(non_token)),
        Err(ContractError::DeclarationValueNotToken { .. })
    ));

    let valid = lua.create_table()?;
    valid.set("clock", token.clone())?;
    let copied = registry.validate_declaration(Value::Table(valid.clone()))?;
    let token_id = token_key(&lua, &registry, &token)?;
    valid.set("clock", true)?;
    assert_eq!(copied.iter().collect::<Vec<_>>(), [("clock", &token_id)]);
    Ok(())
}

fn token_key(
    lua: &Lua,
    registry: &ContractRegistry,
    token: &PluginContractToken,
) -> Result<ContractKey, Box<dyn Error>> {
    let declaration = lua.create_table()?;
    declaration.set("field", token.clone())?;
    let copied = registry.validate_declaration(Value::Table(declaration))?;
    let key = copied.iter().map(|(_, key)| key.clone()).next();
    key.ok_or_else(|| "the declaration copies its field".into())
}

fn contract_name(authority: &str, name: &str) -> ContractName {
    match ContractName::new(authority, name) {
        Ok(name) => name,
        Err(error) => panic!("test contract name is valid: {error}"),
    }
}
