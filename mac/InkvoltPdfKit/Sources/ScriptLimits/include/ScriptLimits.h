#ifndef SCRIPT_LIMITS_H
#define SCRIPT_LIMITS_H

#include <stdbool.h>
#include <JavaScriptCore/JavaScriptCore.h>

/// Called on the script's thread while it runs, about every `limit` seconds of its CPU time; true ends the script at
/// once (as an uncatchable termination).
typedef bool (*inkv_js_should_stop)(JSContextRef ctx, void *context);

/// Arms JavaScriptCore's watchdog for every context of `group`: `should_stop` is asked after `limit` seconds of script
/// CPU time (and, while it answers false and re-arms, again after each further `limit`).
void inkv_js_set_time_limit(JSContextGroupRef group, double limit, inkv_js_should_stop should_stop, void *context);

/// Disarms the watchdog.
void inkv_js_clear_time_limit(JSContextGroupRef group);

#endif
