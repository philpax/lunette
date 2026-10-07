-- Production source reload re-executes these requires in the new contract epoch.
local desktop = require '@lunette-desktop'
local composition = require './composition'
local testing = require '@testing'

testing.host.useConfiguration 'examples/ui'
local form = require 'form'
testing.host.useConfiguration 'lua/lunette-desktop/tests/support/vr-migration'

local observed = {}
local ledger = { activations = 0, ended = 0, actions = 0, events = {}, releases = 0, cancels = 0 }
_G.vrMigration = { services = observed, ledger = ledger }
desktop.run(composition.options(_G.vrMigrationProvider, observed, ledger, form))
