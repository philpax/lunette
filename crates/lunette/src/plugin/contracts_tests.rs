use mlua::{Lua, Value};

use super::contracts::{ContractError, ContractName, ContractRegistry};

#[test]
fn contract_registry_identity() -> mlua::Result<()> {
    let registry = ContractRegistry::new();
    let first = registry
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;
    let different_schema = registry
        .declare(contract_name("example", "clock"), 2)
        .map_err(mlua::Error::external)?;
    assert_ne!(
        registry
            .validate_token(&first)
            .map_err(mlua::Error::external)?,
        registry
            .validate_token(&different_schema)
            .map_err(mlua::Error::external)?
    );

    let duplicate = registry.declare(contract_name("example", "clock"), 1);
    assert!(matches!(
        duplicate,
        Err(ContractError::DuplicateIdentity { .. })
    ));

    let other_authority = registry
        .declare(contract_name("other", "clock"), 1)
        .map_err(mlua::Error::external)?;
    assert_ne!(
        registry
            .validate_token(&first)
            .map_err(mlua::Error::external)?,
        registry
            .validate_token(&other_authority)
            .map_err(mlua::Error::external)?
    );
    assert_eq!(
        registry
            .validate_token(&first)
            .map_err(mlua::Error::external)?
            .epoch(),
        1
    );
    assert_eq!(
        registry
            .validate_token(&first)
            .map_err(mlua::Error::external)?
            .ordinal(),
        1
    );
    assert_eq!(
        registry
            .validate_token(&different_schema)
            .map_err(mlua::Error::external)?
            .ordinal(),
        2
    );
    Ok(())
}

#[test]
fn declaration_shape_rejected() -> mlua::Result<()> {
    let lua = Lua::new();
    let registry = ContractRegistry::new();
    let token = registry
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;

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
    let foreign_token = foreign_registry
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;
    let foreign = lua.create_table()?;
    foreign.set("clock", foreign_token)?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(foreign)),
        Err(ContractError::ForeignToken { .. })
    ));

    let valid = lua.create_table()?;
    valid.set("clock", token.clone())?;
    let copied = registry
        .validate_declaration(Value::Table(valid.clone()))
        .map_err(mlua::Error::external)?;
    let token_id = registry
        .validate_token(&token)
        .map_err(mlua::Error::external)?;
    assert_eq!(copied.get("clock"), Some(token_id));

    valid.set("clock", true)?;
    assert_eq!(copied.get("clock"), Some(token_id));
    Ok(())
}

#[test]
fn stale_contract_epoch() -> mlua::Result<()> {
    let registry = ContractRegistry::new();
    let old = registry
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;
    let old_id = registry
        .validate_token(&old)
        .map_err(mlua::Error::external)?;

    registry.retire_epoch().map_err(mlua::Error::external)?;
    assert_eq!(registry.epoch(), 2);
    assert!(matches!(
        registry.validate_token(&old),
        Err(ContractError::RetiredToken { .. })
    ));

    let current = registry
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;
    let current_id = registry
        .validate_token(&current)
        .map_err(mlua::Error::external)?;
    assert_ne!(old_id, current_id);
    assert_eq!(current_id.epoch(), 2);
    assert_eq!(current_id.ordinal(), 1);
    Ok(())
}

#[test]
fn frozen_wrapper_binding_is_exact_and_one_time() -> mlua::Result<()> {
    let lua = Lua::new();
    let registry = ContractRegistry::new();
    let clock = registry
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;
    let log = registry
        .declare(contract_name("example", "log"), 1)
        .map_err(mlua::Error::external)?;

    let mutable = lua.create_table()?;
    assert!(matches!(
        registry.bind_token(&clock, &mutable),
        Err(ContractError::WrapperNotFrozen)
    ));
    mutable.set_readonly(true);
    registry
        .bind_token(&clock, &mutable)
        .map_err(mlua::Error::external)?;

    let declaration = lua.create_table()?;
    declaration.set("clock", mutable.clone())?;
    let copied = registry
        .validate_declaration(Value::Table(declaration))
        .map_err(mlua::Error::external)?;
    assert_eq!(
        copied.get("clock"),
        Some(
            registry
                .validate_token(&clock)
                .map_err(mlua::Error::external)?
        )
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
fn stale_bound_wrapper_is_rejected_after_epoch_retirement() -> mlua::Result<()> {
    let lua = Lua::new();
    let registry = ContractRegistry::new();
    let token = registry
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;
    let wrapper = lua.create_table()?;
    wrapper.set_readonly(true);
    registry
        .bind_token(&token, &wrapper)
        .map_err(mlua::Error::external)?;

    registry.retire_epoch().map_err(mlua::Error::external)?;
    let declaration = lua.create_table()?;
    declaration.set("clock", wrapper)?;
    assert!(matches!(
        registry.validate_declaration(Value::Table(declaration)),
        Err(ContractError::RetiredWrapper { .. })
    ));
    Ok(())
}

#[test]
fn shared_registry_reuse() -> mlua::Result<()> {
    let lua = Lua::new();
    let owner = ContractRegistry::new();
    let first_runtime = owner.clone();
    let second_runtime = owner.clone();
    let token = first_runtime
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;

    let declaration = lua.create_table()?;
    declaration.set("clock", token.clone())?;
    let copied = second_runtime
        .validate_declaration(Value::Table(declaration))
        .map_err(mlua::Error::external)?;
    assert_eq!(copied.len(), 1);
    let token_id = second_runtime
        .validate_token(&token)
        .map_err(mlua::Error::external)?;
    assert_eq!(copied.get("clock"), Some(token_id));

    let duplicate = second_runtime.declare(contract_name("example", "clock"), 1);
    assert!(matches!(
        duplicate,
        Err(ContractError::DuplicateIdentity { .. })
    ));

    let independent = ContractRegistry::new();
    let independent_token = independent
        .declare(contract_name("example", "clock"), 1)
        .map_err(mlua::Error::external)?;
    assert!(matches!(
        second_runtime.validate_token(&independent_token),
        Err(ContractError::ForeignToken { .. })
    ));
    Ok(())
}

fn contract_name(authority: &str, name: &str) -> ContractName {
    match ContractName::new(authority, name) {
        Ok(name) => name,
        Err(error) => panic!("test contract name is valid: {error}"),
    }
}
