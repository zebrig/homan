#include "LocalVQEBridgeTestSupport.h"

#include "LocalVQEExceptionGuard.h"

#include <cerrno>
#include <system_error>

static int throwing_process_frame(
    muesli_localvqe_context_handle_t,
    const float *,
    const float *,
    int,
    float *
) {
    throw std::system_error(
        std::make_error_code(std::errc::invalid_argument),
        "simulated LocalVQE mutex failure"
    );
}

extern "C" int muesli_test_localvqe_guard_system_error(
    char *error_buffer,
    int error_buffer_length
) {
    float mic[1] = {0};
    float reference[1] = {0};
    float output[1] = {0};
    return muesli_localvqe_call_process_frame_guarded(
        throwing_process_frame,
        1,
        mic,
        reference,
        1,
        output,
        error_buffer,
        static_cast<size_t>(error_buffer_length)
    );
}
