#include <stdint.h>
#include <stddef.h>

// 0 generic, 1 configuration, 2 authentication, 3 quota, 4 rate limit,
// 5 timeout, 6 network, 7 server, 8 client.
int32_t ai_input_classify_error(const char *message);

// Returns -1 for empty input. Values may be in any order.
int32_t ai_input_p95(const int32_t *values, size_t length);
