#ifndef MUESLI_LOCALVQE_EXCEPTION_GUARD_H
#define MUESLI_LOCALVQE_EXCEPTION_GUARD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uintptr_t muesli_localvqe_context_handle_t;
typedef int (*muesli_localvqe_process_frame_callback_t)(
    muesli_localvqe_context_handle_t,
    const float *,
    const float *,
    int,
    float *
);

/// Invokes the dynamically loaded C ABI from a C++ exception boundary.
/// LocalVQE normally reports failures as integer status codes, but its GGML
/// runtime can throw std::system_error (for example during process teardown).
/// No C++ exception may unwind through the C and Swift frames above this call.
int muesli_localvqe_call_process_frame_guarded(
    muesli_localvqe_process_frame_callback_t callback,
    muesli_localvqe_context_handle_t context,
    const float *mic,
    const float *reference,
    int hop_samples,
    float *output,
    char *error_buffer,
    size_t error_buffer_length
);

#ifdef __cplusplus
}
#endif

#endif
