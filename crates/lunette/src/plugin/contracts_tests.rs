use std::error::Error;

use mlua::{Lua, Value};

use super::contracts::{ContractError, ContractName, ContractRegistry};

#[test]
fn contract_registry_identity() -> Result<(), Box<dyn Error>> {
    let registry = ContractRegistry::new();
    let first = registry.declare(contract_name("example", "clock"), 1)?;
    let different_schema = registry.declare(contract_name("example", "clock"), 2)?;
    assert_ne!(
        registry.validate_token(&first)?,
        registry.validate_token(&different_schema)?
    );

    let duplicate = registry.declare(contract_name("example", "clock"), 1);
    assert!(matches!(
        duplicate,
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

    let other_authority = registry.declare(contract_name("other", "clock"), 1)?;
    assert_ne!(
        registry.validate_token(&first)?,
        registry.validate_token(&other_authority)?
    );
    Ok(())
}

#[test]
fn declaration_shape_rejected() -> Result<(), Box<dyn Error>> {
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

    let forged_table = lua.create_table()?;
    forged_table.set("epoch", 1)?;
    let forged = lua.create_table()?;
    forged.set("clock", forged_table)?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(forged)),
        Err(ContractError::UnboundWrapper { .. })
    ));

    let foreign_registry = ContractRegistry::new();
    let foreign_token = foreign_registry.declare(contract_name("example", "clock"), 1)?;
    let foreign = lua.create_table()?;
    foreign.set("clock", foreign_token)?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(foreign)),
        Err(ContractError::ForeignToken { .. })
    ));

    let valid = lua.create_table()?;
    valid.set("clock", token.clone())?;
    let copied = registry.validate_declaration(Value::Table(valid.clone()))?;
    let token_id = registry.validate_token(&token)?;
    assert_eq!(copied.iter().collect::<Vec<_>>(), [("clock", &token_id)]);

    valid.set("clock", true)?;
    assert_eq!(copied.iter().collect::<Vec<_>>(), [("clock", &token_id)]);
    Ok(())
}

/// The host retires an epoch by replacing its registry, so a token from the
/// dropped registry is retired and its identity may be declared again.
#[test]
fn stale_contract_epoch() -> Result<(), Box<dyn Error>> {
    let old = ContractRegistry::new().declare(contract_name("example", "clock"), 1)?;

    let registry = ContractRegistry::new();
    assert!(matches!(
        registry.validate_token(&old),
        Err(ContractError::RetiredToken { .. })
    ));
    let current = registry.declare(contract_name("example", "clock"), 1)?;
    registry.validate_token(&current)?;
    Ok(())
}

#[test]
fn frozen_wrapper_binding_is_exact_and_one_time() -> Result<(), Box<dyn Error>> {
    let lua = Lua::new();
    let registry = ContractRegistry::new();
    let clock = registry.declare(contract_name("example", "clock"), 1)?;
    let log = registry.declare(contract_name("example", "log"), 1)?;

    let mutable = lua.create_table()?;
    assert!(matches!(
        registry.bind_token(&clock, &mutable),
        Err(ContractError::WrapperNotFrozen)
    ));
    mutable.set_readonly(true);
    registry.bind_token(&clock, &mutable)?;

    let declaration = lua.create_table()?;
    declaration.set("clock", mutable.clone())?;
    let copied = registry.validate_declaration(Value::Table(declaration))?;
    assert_eq!(
        copied.iter().collect::<Vec<_>>(),
        [("clock", &registry.validate_token(&clock)?)]
    );

    assert!(matches!(
        registry.bind_token(&clock, &mutable),
        Err(ContractError::TokenAlreadyBound)
    ));
    assert!(matches!(
        registry.bind_token(&log, &mutable),
        Err(ContractError::WrapperAlreadyBound)
    ));

    let repackaged = lua.create_table()?;
    repackaged.set("token", mutable)?;
    repackaged.set_readonly(true);
    let repackaged_declaration = lua.create_table()?;
    repackaged_declaration.set("clock", repackaged)?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(repackaged_declaration)),
        Err(ContractError::UnboundWrapper { .. })
    ));
    Ok(())
}

#[test]
fn a_wrapper_bound_in_another_registry_is_unbound() -> Result<(), Box<dyn Error>> {
    let lua = Lua::new();
    let previous = ContractRegistry::new();
    let token = previous.declare(contract_name("example", "clock"), 1)?;
    let wrapper = lua.create_table()?;
    wrapper.set_readonly(true);
    previous.bind_token(&token, &wrapper)?;

    let registry = ContractRegistry::new();
    let declaration = lua.create_table()?;
    declaration.set("clock", wrapper)?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(declaration)),
        Err(ContractError::UnboundWrapper { .. })
    ));
    Ok(())
}

/// A token error names where the token was presented: the declaration field
/// that holds it, or the contract it was declared for when it is bound.
#[test]
fn token_errors_name_the_field_or_contract() -> Result<(), Box<dyn Error>> {
    let lua = Lua::new();
    let registry = ContractRegistry::new();
    let foreign_registry = ContractRegistry::new();
    let foreign = foreign_registry.declare(contract_name("example", "clock"), 1)?;

    let declaration = lua.create_table()?;
    declaration.set("timer", foreign.clone())?;
    let declared = registry
        .validate_declaration(Value::Table(declaration))
        .err()
        .map(|error| error.to_string());
    assert_eq!(
        declared.as_deref(),
        Some("plugin contract: the token in declaration field 'timer' is from another registry")
    );

    let wrapper = lua.create_table()?;
    wrapper.set_readonly(true);
    let bound = registry
        .bind_token(&foreign, &wrapper)
        .err()
        .map(|error| error.to_string());
    assert_eq!(
        bound.as_deref(),
        Some("plugin contract: the token for example/clock@1 is from another registry")
    );
    Ok(())
}

fn contract_name(authority: &str, name: &str) -> ContractName {
    match ContractName::new(authority, name) {
        Ok(name) => name,
        Err(error) => panic!("test contract name is valid: {error}"),
    }
}
