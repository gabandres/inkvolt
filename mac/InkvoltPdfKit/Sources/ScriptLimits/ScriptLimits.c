// JavaScriptCore has no public way to stop a running script; its watchdog does it. The two functions are exported by
// JavaScriptCore.framework (in its SDK stubs) but declared only in its private JSContextRefPrivate.h, so they are declared
// here with the signatures WebKit documents there. Form scripts must never be able to hang the app.

#include "ScriptLimits.h"

typedef bool (*JSShouldTerminateCallback)(JSContextRef ctx, void *context);
extern void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit, JSShouldTerminateCallback callback, void *context);
extern void JSContextGroupClearExecutionTimeLimit(JSContextGroupRef group);

void inkv_js_set_time_limit(JSContextGroupRef group, double limit, inkv_js_should_stop should_stop, void *context) {
    JSContextGroupSetExecutionTimeLimit(group, limit, should_stop, context);
}

void inkv_js_clear_time_limit(JSContextGroupRef group) {
    JSContextGroupClearExecutionTimeLimit(group);
}
