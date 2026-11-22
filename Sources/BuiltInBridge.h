#ifndef CLAIM_CHECK_BUILT_IN_BRIDGE_H
#define CLAIM_CHECK_BUILT_IN_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

typedef struct llama_model CCBuiltInModel;
typedef bool (*CCBuiltInCancellation)(void *data);

typedef enum {
    CC_BUILT_IN_OK,
    CC_BUILT_IN_CANCELLED,
    CC_BUILT_IN_MODEL_ERROR,
    CC_BUILT_IN_PROMPT_TOO_LONG,
    CC_BUILT_IN_RUNTIME_ERROR,
    CC_BUILT_IN_INCOMPLETE,
} CCBuiltInStatus;

CCBuiltInStatus cc_built_in_open(
    const char *path, CCBuiltInCancellation cancelled, void *data, CCBuiltInModel **model);
void cc_built_in_close(CCBuiltInModel *model);

CCBuiltInStatus cc_built_in_generate(
    CCBuiltInModel *model,
    const char *system, size_t system_length,
    const char *user, size_t user_length,
    CCBuiltInCancellation cancelled, void *data,
    char **response);
CCBuiltInStatus cc_built_in_generate_evidence(
    CCBuiltInModel *model,
    const char *system, size_t system_length,
    const char *user, size_t user_length,
    CCBuiltInCancellation cancelled, void *data,
    char **response);
void cc_built_in_free_response(char *response);

#endif
