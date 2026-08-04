#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef void *(*options_new_fn)(void);
typedef void (*options_free_fn)(void *);
typedef int (*options_set_model_path_fn)(void *, const char *);
typedef int (*options_set_backend_fn)(void *, const char *);
typedef int (*options_set_threads_fn)(void *, int);
typedef void *(*new_with_options_fn)(void *);
typedef void (*free_context_fn)(void *);
typedef int (*sample_rate_fn)(void *);
typedef int (*hop_length_fn)(void *);
typedef int (*process_frame_fn)(void *, const float *, const float *, int, float *);

static void *required_symbol(void *library, const char *name) {
    dlerror();
    void *symbol = dlsym(library, name);
    const char *error = dlerror();
    if (error != NULL || symbol == NULL) {
        fprintf(stderr, "Missing LocalVQE symbol %s: %s\n", name, error != NULL ? error : "unknown error");
        exit(1);
    }
    return symbol;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <liblocalvqe.dylib> <model.gguf>\n", argv[0]);
        return 2;
    }

    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "Could not load LocalVQE runtime: %s\n", dlerror());
        return 1;
    }

    options_new_fn options_new = (options_new_fn)required_symbol(library, "localvqe_options_new");
    options_free_fn options_free = (options_free_fn)required_symbol(library, "localvqe_options_free");
    options_set_model_path_fn set_model_path =
        (options_set_model_path_fn)required_symbol(library, "localvqe_options_set_model_path");
    options_set_backend_fn set_backend =
        (options_set_backend_fn)required_symbol(library, "localvqe_options_set_backend");
    options_set_threads_fn set_threads =
        (options_set_threads_fn)required_symbol(library, "localvqe_options_set_threads");
    new_with_options_fn new_with_options =
        (new_with_options_fn)required_symbol(library, "localvqe_new_with_options");
    free_context_fn free_context = (free_context_fn)required_symbol(library, "localvqe_free");
    sample_rate_fn sample_rate = (sample_rate_fn)required_symbol(library, "localvqe_sample_rate");
    hop_length_fn hop_length = (hop_length_fn)required_symbol(library, "localvqe_hop_length");
    process_frame_fn process_frame =
        (process_frame_fn)required_symbol(library, "localvqe_process_frame_f32");

    void *options = options_new();
    if (options == NULL ||
        set_model_path(options, argv[2]) != 0 ||
        set_backend(options, "CPU") != 0 ||
        set_threads(options, 2) != 0) {
        fprintf(stderr, "Could not configure LocalVQE runtime options\n");
        if (options != NULL) {
            options_free(options);
        }
        dlclose(library);
        return 1;
    }

    void *context = new_with_options(options);
    options_free(options);
    if (context == NULL) {
        fprintf(stderr, "LocalVQE could not load its bundled model or CPU backend\n");
        dlclose(library);
        return 1;
    }

    int rate = sample_rate(context);
    int hop = hop_length(context);
    if (rate != 16000 || hop != 256) {
        fprintf(stderr, "Unexpected LocalVQE format: sampleRate=%d hopLength=%d\n", rate, hop);
        free_context(context);
        dlclose(library);
        return 1;
    }

    float *microphone = calloc((size_t)hop, sizeof(float));
    float *reference = calloc((size_t)hop, sizeof(float));
    float *output = calloc((size_t)hop, sizeof(float));
    if (microphone == NULL || reference == NULL || output == NULL) {
        fprintf(stderr, "Could not allocate LocalVQE smoke-test buffers\n");
        free(microphone);
        free(reference);
        free(output);
        free_context(context);
        dlclose(library);
        return 1;
    }

    int status = process_frame(context, microphone, reference, hop, output);
    free(microphone);
    free(reference);
    free(output);
    free_context(context);
    dlclose(library);

    if (status != 0) {
        fprintf(stderr, "LocalVQE rejected a correctly sized audio frame (status %d)\n", status);
        return 1;
    }

    printf("LocalVQE runtime smoke test passed (16000 Hz, 256-sample frames).\n");
    return 0;
}
