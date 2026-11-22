#include "BuiltInBridge.h"
#include "ggml-metal.h"
#include "llama.h"

#include <limits.h>
#include <pthread.h>
#include <stdlib.h>

enum {
    CONTEXT_TOKENS = 8192,
    OUTPUT_TOKENS = 1536,
    PREFILL_BATCH_TOKENS = 128,
    RESPONSE_BYTES = 98304,
};

static const char *const result_grammar =
    "root ::= ws \"{\" ws judgment ws \"}\" ws\n"
    "evidence-root ::= ws \"{\" ws evidence-list ws \"}\" ws\n"
    "judgment ::= \"\\\"outcome\\\"\" ws \":\" ws (flags | empty)\n"
    "evidence-list ::= key ws \":\" ws \"[\" ws (evidence-finding (ws \",\" ws evidence-finding){0,3})? ws \"]\"\n"
    "flags ::= \"\\\"findings\\\"\" ws \",\" ws key ws \":\" ws \"[\" ws finding (ws \",\" ws finding){0,4} ws \"]\"\n"
    "empty ::= (\"\\\"no_flags\\\"\" | \"\\\"needs_context\\\"\") ws \",\" ws key ws \":\" ws \"[\" ws \"]\"\n"
    "key ::= \"\\\"findings\\\"\"\n"
    "finding ::= \"{\" ws finding-fields ws \"}\"\n"
    "evidence-finding ::= \"{\" ws finding-fields ws \",\" ws evidence ws \"}\"\n"
    "finding-fields ::= \"\\\"ruleID\\\"\" ws \":\" ws string ws \",\" ws \"\\\"quote\\\"\" ws \":\" ws string ws \",\" ws \"\\\"reason\\\"\" ws \":\" ws string ws \",\" ws \"\\\"verify\\\"\" ws \":\" ws string\n"
    "evidence ::= \"\\\"evidence\\\"\" ws \":\" ws \"{\" ws \"\\\"claimQuote\\\"\" ws \":\" ws string ws \",\" ws \"\\\"measure\\\"\" ws \":\" ws optional-string ws \",\" ws \"\\\"group\\\"\" ws \":\" ws optional-string ws \",\" ws \"\\\"period\\\"\" ws \":\" ws optional-string ws \",\" ws \"\\\"coverage\\\"\" ws \":\" ws coverage ws \"}\"\n"
    "coverage ::= \"\\\"full\\\"\" | \"\\\"subset\\\"\" | \"\\\"unknown\\\"\"\n"
    "optional-string ::= \"\\\"\\\"\" | string\n"
    "string ::= \"\\\"\" character+ \"\\\"\"\n"
    "character ::= [^\"\\\\\\x00-\\x1F] | \"\\\\\" ([\"\\\\/bfnrt] | \"u\" [0-9a-fA-F]{4})\n"
    "ws ::= [ \\t\\r\\n]{0,8}\n";

struct cancellation {
    CCBuiltInCancellation check;
    void *data;
};

static ggml_backend_dev_t local_accelerators[2];

static bool is_cancelled(void *data) {
    const struct cancellation *state = data;
    return state->check(state->data);
}

static bool continue_loading(float progress, void *data) {
    (void) progress;
    return !is_cancelled(data);
}

static void discard_log(enum ggml_log_level level, const char *message, void *data) {
    (void) level;
    (void) message;
    (void) data;
}

static void initialize_backend(void) {
    llama_log_set(discard_log, NULL);
    llama_backend_init();

    ggml_backend_reg_t metal = ggml_backend_metal_reg();
    if (ggml_backend_reg_dev_count(metal) > 0) {
        ggml_backend_dev_t device = ggml_backend_reg_dev_get(metal, 0);
        size_t free_bytes = 0;
        size_t total_bytes = 0;
        ggml_backend_dev_memory(device, &free_bytes, &total_bytes);
        if (total_bytes > 0) {
            local_accelerators[0] = device;
        }
    }
}

CCBuiltInStatus cc_built_in_open(
    const char *path, CCBuiltInCancellation cancelled, void *data, CCBuiltInModel **model) {
    static pthread_once_t init = PTHREAD_ONCE_INIT;
    struct cancellation cancellation = {cancelled, data};
    *model = NULL;
    if (is_cancelled(&cancellation)) {
        return CC_BUILT_IN_CANCELLED;
    }
    pthread_once(&init, initialize_backend);

    struct llama_model_params params = llama_model_default_params();
    params.devices = local_accelerators;
    params.n_gpu_layers = local_accelerators[0] ? -1 : 0;
    params.progress_callback = continue_loading;
    params.progress_callback_user_data = &cancellation;

    *model = llama_model_load_from_file(path, params);
    if (is_cancelled(&cancellation)) {
        if (*model) {
            llama_model_free(*model);
            *model = NULL;
        }
        return CC_BUILT_IN_CANCELLED;
    }
    return *model ? CC_BUILT_IN_OK : CC_BUILT_IN_MODEL_ERROR;
}

void cc_built_in_close(CCBuiltInModel *model) {
    llama_model_free(model);
}

struct prompt_part {
    const char *bytes;
    size_t length;
    bool parse_special;
};

static int32_t tokenize_prompt(
    const struct llama_vocab *vocab, const char *system, size_t system_length,
    const char *user, size_t user_length, llama_token *tokens, int32_t capacity) {
    // Qwen3's official chat template with enable_thinking=false.
    static const char system_header[] = "<|im_start|>system\n";
    static const char user_header[] = "<|im_end|>\n<|im_start|>user\n";
    static const char assistant_header[] = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    // Encode message content as plain text so the template controls chat turns.
    const struct prompt_part parts[] = {
        {system_header, sizeof(system_header) - 1, true},
        {system, system_length, false},
        {user_header, sizeof(user_header) - 1, true},
        {user, user_length, false},
        {assistant_header, sizeof(assistant_header) - 1, true},
    };
    int32_t count = 0;
    for (size_t index = 0; index < sizeof(parts) / sizeof(parts[0]); index++) {
        if (parts[index].length > INT32_MAX) {
            return -1;
        }
        const int32_t added = llama_tokenize(
            vocab, parts[index].bytes, (int32_t) parts[index].length, tokens + count,
            capacity - count, index == 0, parts[index].parse_special);
        if (added < 0) {
            return -1;
        }
        count += added;
    }
    return count;
}

static CCBuiltInStatus decode_prompt(
    struct llama_context *context, llama_token *tokens, int32_t count,
    struct cancellation *cancellation) {
    for (int32_t position = 0; position < count; position += PREFILL_BATCH_TOKENS) {
        if (is_cancelled(cancellation)) {
            return CC_BUILT_IN_CANCELLED;
        }
        const int32_t remaining = count - position;
        const int32_t batch_size = remaining < PREFILL_BATCH_TOKENS ? remaining : PREFILL_BATCH_TOKENS;
        if (llama_decode(context, llama_batch_get_one(tokens + position, batch_size)) != 0) {
            return is_cancelled(cancellation) ? CC_BUILT_IN_CANCELLED : CC_BUILT_IN_RUNTIME_ERROR;
        }
    }
    return CC_BUILT_IN_OK;
}

static CCBuiltInStatus sample_response(
    struct llama_context *context, const struct llama_vocab *vocab,
    struct llama_sampler *sampler, struct cancellation *cancellation,
    char **response) {
    char *buffer = malloc(RESPONSE_BYTES + 1);
    if (!buffer) {
        return CC_BUILT_IN_RUNTIME_ERROR;
    }
    int32_t written = 0;
    CCBuiltInStatus status = CC_BUILT_IN_INCOMPLETE;
    for (int generated = 0; generated <= OUTPUT_TOKENS; generated++) {
        if (is_cancelled(cancellation)) {
            status = CC_BUILT_IN_CANCELLED;
            break;
        }
        llama_token token = llama_sampler_sample(sampler, context, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            if (written > 0) {
                buffer[written] = '\0';
                *response = buffer;
                return CC_BUILT_IN_OK;
            }
            break;
        }
        if (generated == OUTPUT_TOKENS) {
            break;
        }
        const int32_t length = llama_token_to_piece(
            vocab, token, buffer + written, RESPONSE_BYTES - written, 0, false);
        if (length <= 0) {
            break;
        }
        written += length;
        if (llama_decode(context, llama_batch_get_one(&token, 1)) != 0) {
            status = is_cancelled(cancellation) ? CC_BUILT_IN_CANCELLED : CC_BUILT_IN_RUNTIME_ERROR;
            break;
        }
    }
    free(buffer);
    return status;
}

static CCBuiltInStatus generate(
    CCBuiltInModel *model,
    const char *system, size_t system_length,
    const char *user, size_t user_length,
    CCBuiltInCancellation cancelled, void *data,
    char **response, const char *grammar_root) {
    struct cancellation cancellation = {cancelled, data};
    *response = NULL;
    if (is_cancelled(&cancellation)) {
        return CC_BUILT_IN_CANCELLED;
    }

    const struct llama_vocab *vocab = llama_model_get_vocab(model);
    llama_token tokens[CONTEXT_TOKENS - OUTPUT_TOKENS];
    const int32_t count = tokenize_prompt(
        vocab, system, system_length, user, user_length, tokens, CONTEXT_TOKENS - OUTPUT_TOKENS);
    if (count < 0) {
        return CC_BUILT_IN_PROMPT_TOO_LONG;
    }
    if (count == 0) {
        return CC_BUILT_IN_RUNTIME_ERROR;
    }

    struct llama_context_params params = llama_context_default_params();
    params.n_ctx = CONTEXT_TOKENS;
    params.n_batch = PREFILL_BATCH_TOKENS;
    params.n_ubatch = PREFILL_BATCH_TOKENS;
    params.n_threads = 4;
    params.n_threads_batch = 4;
    params.abort_callback = is_cancelled;
    params.abort_callback_data = &cancellation;
    struct llama_context *context = llama_init_from_model(model, params);
    if (!context) {
        return is_cancelled(&cancellation) ? CC_BUILT_IN_CANCELLED : CC_BUILT_IN_RUNTIME_ERROR;
    }

    struct llama_sampler *grammar = llama_sampler_init_grammar(vocab, result_grammar, grammar_root);
    if (!grammar) {
        llama_free(context);
        return CC_BUILT_IN_RUNTIME_ERROR;
    }
    struct llama_sampler *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, grammar);
    llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.0f, 0.0f, 1.0f));
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    CCBuiltInStatus status = decode_prompt(context, tokens, count, &cancellation);
    if (status == CC_BUILT_IN_OK) {
        status = sample_response(context, vocab, sampler, &cancellation, response);
    }
    llama_sampler_free(sampler);
    llama_free(context);
    return status;
}

CCBuiltInStatus cc_built_in_generate(
    CCBuiltInModel *model, const char *system, size_t system_length,
    const char *user, size_t user_length, CCBuiltInCancellation cancelled, void *data, char **response) {
    return generate(model, system, system_length, user, user_length, cancelled, data, response, "root");
}

CCBuiltInStatus cc_built_in_generate_evidence(
    CCBuiltInModel *model, const char *system, size_t system_length,
    const char *user, size_t user_length, CCBuiltInCancellation cancelled, void *data, char **response) {
    return generate(model, system, system_length, user, user_length, cancelled, data, response, "evidence-root");
}

void cc_built_in_free_response(char *response) {
    free(response);
}
