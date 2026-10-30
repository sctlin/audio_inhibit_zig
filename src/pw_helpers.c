#include "pw_helpers.h"

int zig_pw_registry_add_listener(struct pw_registry *registry,
                                 struct spa_hook *listener,
                                 const struct pw_registry_events *events,
                                 void *data) {
  return pw_registry_add_listener(registry, listener, events, data);
}

int zig_pw_core_add_listener(struct pw_core *object, struct spa_hook *listener,
                             const struct pw_core_events *events, void *data) {
  return pw_core_add_listener(object, listener, events, data);
}

int zig_pw_core_sync(struct pw_core *object, uint32_t id, int seq) {
  return pw_core_sync(object, id, seq);
}
