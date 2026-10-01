-- A native panic raised inside an initializer.
return function(plugin)
  panicking_runtime = plugin.runtime()
  local definition = plugin.define({}, {}, function()
    panic_now()
    return {}
  end, 'panicking initializer')
  panicking_instance = panicking_runtime:use(definition, {})
  panicking_instance:enable()
end
