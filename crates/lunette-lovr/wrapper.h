// bindgen parses this translation unit. api.h provides the luax_* entry
// points and, transitively, the Variant type that stores the restart
// cookie. os.h provides the platform hooks. util.h provides the log
// callback and the reference counting that owns every LOVR object.
//
// graphics.h and image.h provide the texture and image APIs the dmabuf and
// wl_shm import paths are written against: lovrTextureCreate with
// TextureInfo.foreign, the import barrier wrappers, and lovrImageCreateRaw
// for performing a shared-memory upload.
//
// event.h provides lovrEventPush and the CustomEvent the lun* callbacks are
// delivered through.
//
// headset.h provides the composition layer API. The runtime's layer limit
// bounds the layer pool's size.
#include "api/api.h"
#include "core/os.h"
#include "util.h"
#include "modules/event/event.h"
#include "modules/graphics/graphics.h"
#include "modules/data/image.h"
#include "modules/headset/headset.h"

// The Vulkan handles LOVR creates. These are defined in core/gpu_vk.c and
// declared by no header: headset.c forward-declares them and is the sole
// consumer. Repeating the declarations here adds no header to the fork and
// keeps the patch set minimal. The four signatures are stable across the
// upstream branch.
#include <stdint.h>
uintptr_t gpu_vk_get_instance(void);
uintptr_t gpu_vk_get_physical_device(void);
uintptr_t gpu_vk_get_device(void);
uintptr_t gpu_vk_get_queue(uint32_t* queueFamilyIndex, uint32_t* queueIndex);
