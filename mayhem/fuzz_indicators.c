/*
 * In-process libFuzzer harness for Tulip Indicators.
 *
 * Authored for the mayhemheroes integration. The upstream Mayhem target was the file-input
 * `cli` utility (`cli cos @@ out`), but cli.c is documented "not memory safe ... for testing
 * only" and, driven with a fixed indicator, dead-ends in its text option-parser (near-zero
 * coverage of the actual library). This harness drives the REAL indicator library over the
 * same code path (compute an indicator over a numeric series) so the fuzzer exercises the
 * math/buffer logic in indicators/*.c — the code worth fuzzing — instead of a throwaway CLI
 * parser. The Mayhem target keeps the historical name `cli` so run history is preserved.
 *
 * Correctness (avoid harness-induced false positives): we mirror what a correct library
 * consumer does. Options are constrained to small positive integers (avoids feeding a huge
 * double into the indicators' `(int)options[i]` casts, which would be pure UBSan
 * float-cast-overflow noise, not a real library defect). Output buffers are sized exactly as
 * the library contract requires — `size - info->start(options)` elements per output — by
 * calling the indicator's own start() function, so any ASan/UBSan hit reflects a genuine bug
 * in the fuzzed code rather than an under-allocation in the harness.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "indicators.h"

#define MAX_SAMPLES 4096

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* byte 0 selects the indicator; the next info->options bytes pick option values;
       the remainder is reinterpreted as the input sample series. */
    if (size < 1) return 0;

    const ti_indicator_info *info = &ti_indicators[data[0] % TI_INDICATOR_COUNT];
    if (!info->name) return 0;
    ++data; --size;

    /* options: small positive integers in [1, 100] derived from the input bytes. */
    TI_REAL options[TI_MAXINDPARAMS];
    for (int i = 0; i < info->options; ++i) {
        uint8_t b = size ? data[(size_t)i % size] : (uint8_t)(i + 1);
        options[i] = (TI_REAL)(1 + (b % 100));
    }

    const int opt_bytes = info->options;  /* consume a few bytes as options, rest as samples */
    if ((size_t)opt_bytes < size) { data += opt_bytes; size -= (size_t)opt_bytes; }
    else size = 0;

    int n = (int)(size / sizeof(double));
    if (n < 1) return 0;
    if (n > MAX_SAMPLES) n = MAX_SAMPLES;

    /* one shared, read-only sample buffer feeds every required input series. */
    TI_REAL *series = (TI_REAL *)malloc(sizeof(TI_REAL) * (size_t)n);
    if (!series) return 0;
    memcpy(series, data, sizeof(double) * (size_t)n);

    const TI_REAL *inputs[TI_MAXINDPARAMS];
    for (int i = 0; i < info->inputs; ++i) inputs[i] = series;

    /* size each output exactly as the library contract requires: size - start(options). */
    int start = info->start(options);
    int out_len = n - start;
    if (out_len < 1) out_len = 1;  /* indicator returns early without writing when size <= start */

    TI_REAL *outputs[TI_MAXINDPARAMS] = {0};
    int allocated = 0;
    for (int i = 0; i < info->outputs; ++i) {
        outputs[i] = (TI_REAL *)malloc(sizeof(TI_REAL) * (size_t)out_len);
        if (!outputs[i]) { allocated = i; goto cleanup; }
    }
    allocated = info->outputs;

    info->indicator(n, (TI_REAL const *const *)inputs, options, (TI_REAL *const *)outputs);

cleanup:
    for (int i = 0; i < allocated; ++i) free(outputs[i]);
    free(series);
    return 0;
}
