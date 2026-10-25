-- Uploads immutable instance data and records draws with aligned uniform-buffer ranges.

local upload = {}

export type Layout = {
  name: string,
  slots: number,
  batch: number,
  bytes: number,
  stride: number,
}

function upload.layout(name: string, slots: number, batch: number): Layout
  local bytes = slots * batch * 16
  local align = math.max(16, lovr.graphics.getLimits().uniformBufferAlign)
  return { name = name, slots = slots, batch = batch, bytes = bytes, stride = math.ceil(bytes / align) * align }
end

function upload.draw(layout: Layout, pass: Pass, mesh: Mesh, transform: Mat4, data: { number }, total: number): ()
  if total == 0 then
    return
  end
  local batches = math.ceil(total / layout.batch)
  local buffer = lovr.graphics.newBuffer('vec4', ((batches - 1) * layout.stride + layout.bytes) / 16)
  local ok, failure = pcall(function(): ()
    if layout.stride == layout.bytes then
      buffer:setData(data, 1, 1, total * layout.slots)
    else
      local first = 0
      while first < total do
        local count = math.min(layout.batch, total - first)
        buffer:setData(
          data,
          first / layout.batch * layout.stride / 16 + 1,
          first * layout.slots * 4 + 1,
          count * layout.slots
        )
        first += count
      end
    end
    local first = 0
    while first < total do
      local count = math.min(layout.batch, total - first)
      pass:send(layout.name, buffer, first / layout.batch * layout.stride, layout.bytes)
      pass:draw(mesh, transform, count)
      first += count
    end
  end)
  -- Pass:send retains the buffer. A later draw must not overwrite data that an earlier pass has not submitted.
  buffer:release()
  if not ok then
    error(failure, 0)
  end
end

return upload
