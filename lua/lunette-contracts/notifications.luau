-- Notifications: events a user is expected to act on, shown as toasts and kept in a history.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'
local inspection = require '@lunette-contracts/inspection'

local notifications = {}

export type Owner = plugin.Owner
export type Level = 'info' | 'warning' | 'error'

export type Action = {
  read id: string,
  read label: string,
  read run: () -> (),
}

export type Notification = {
  read title: string,
  read body: string?,
  read level: Level?,
  -- Seconds a toast stays before it leaves on its own, before the accessibility timing multiplier; nil uses the
  -- provider's default, and 0 keeps it until it is dismissed.
  read timeout: number?,
  read actions: { read [number]: Action }?,
}

-- A notification in the history. Its actions remain available there after its toast has gone.
export type Entry = {
  read id: number,
  read notification: Notification,
  read owner: Owner,
  read time: number,
}

export type Handle = {
  read dead: boolean,
  read dismiss: (Handle) -> (),
}

export type Service = {
  read notify: (Service, Owner, Notification) -> Handle,
  -- The notifications since the session started, newest last.
  read history: vocabulary.Store<{ read [number]: Entry }>,
  read clearHistory: (Service) -> (),
  read inspect: (Service) -> inspection.Snapshot,
}

export type Capability = plugin.Capability<Service>

notifications.capability = plugin.capability<<Service>> { name = 'lunette/notifications', version = 1 }

return notifications
