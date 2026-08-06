// The translation unit bindgen parses. api.h brings in the luax_* entry points
// and, transitively, the Variant type the restart cookie is carried in; os.h
// brings in the platform hooks; util.h brings in the log callback.
#include "api/api.h"
#include "core/os.h"
#include "util.h"
