// The translation unit bindgen parses. api.h brings in the luax_* entry points
// and, transitively, the Variant type the restart cookie is carried in; os.h
// brings in the platform hooks; util.h brings in the log callback and the
// reference counting every LOVR object is owned through.
//
// graphics.h and image.h bring in the texture surface the dmabuf and wl_shm
// import paths are written against: lovrTextureCreate with TextureInfo.foreign,
// the import barrier wrappers, and lovrImageCreateRaw as the vehicle for a
// shared-memory upload.
//
// event.h brings in lovrEventPush and the CustomEvent the lun* callbacks are
// delivered through.
//
// headset.h brings in the composition layer surface: the runtime's layer limit,
// which is what the layer pool budgets against.
#include "api/api.h"
#include "core/os.h"
#include "util.h"
#include "modules/event/event.h"
#include "modules/graphics/graphics.h"
#include "modules/data/image.h"
#include "modules/headset/headset.h"

// Vulkan handles exported by LOVR without a public header. Repeat the stable
// declarations here instead of adding a header to the vendored fork.
#include <stdint.h>
uintptr_t gpu_vk_get_instance(void);
uintptr_t gpu_vk_get_physical_device(void);
uintptr_t gpu_vk_get_device(void);
uintptr_t gpu_vk_get_queue(uint32_t* queueFamilyIndex, uint32_t* queueIndex);
