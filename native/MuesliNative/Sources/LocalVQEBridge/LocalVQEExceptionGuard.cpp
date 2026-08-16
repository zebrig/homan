#include "LocalVQEExceptionGuard.h"

#include <cstdio>
#include <exception>

extern "C" int muesli_localvqe_call_process_frame_guarded(
    muesli_localvqe_process_frame_callback_t callback,
    muesli_localvqe_context_handle_t context,
    const float *mic,
    const float *reference,
    int hop_samples,
    float *output,
    char *error_buffer,
    size_t error_buffer_length
) {
    try {
        return callback(context, mic, reference, hop_samples, output);
    } catch (const std::exception &error) {
        if (error_buffer != nullptr && error_buffer_length > 0) {
            std::snprintf(
                error_buffer,
                error_buffer_length,
                "LocalVQE C++ exception: %s",
                error.what()
            );
        }
        return -103;
    } catch (...) {
        if (error_buffer != nullptr && error_buffer_length > 0) {
            std::snprintf(
                error_buffer,
                error_buffer_length,
                "LocalVQE C++ exception: unknown exception"
            );
        }
        return -104;
    }
}
