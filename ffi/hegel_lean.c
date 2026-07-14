#include <lean/lean.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef int hegel_result_t;
typedef struct {
  void *library;
} lean_hegel_library;

typedef struct {
  void *value;
  lean_object *library;
  hegel_result_t (*free_value)(void *, void *);
  void *auxiliary;
  void (*free_auxiliary)(void *);
} lean_hegel_handle;

typedef struct {
  void *value;
  lean_object *library;
  hegel_result_t (*free_context)(void *);
  const char *(*last_error)(const void *);
} lean_hegel_context;

typedef struct { char *data; size_t length; size_t capacity; } output_buffer;
typedef void (*hegel_output_callback)(void *, const char *, size_t);
static lean_object *fixed_bytes(const uint8_t *data, size_t len);

static void capture_output(void *user_data, const char *line, size_t length) {
  output_buffer *buffer = user_data;
  size_t needed = buffer->length + length + 1;
  if (needed > buffer->capacity) {
    size_t capacity = buffer->capacity ? buffer->capacity : 256;
    while (capacity < needed) capacity *= 2;
    char *grown = realloc(buffer->data, capacity);
    if (!grown) return;
    buffer->data = grown; buffer->capacity = capacity;
  }
  memcpy(buffer->data + buffer->length, line, length);
  buffer->length += length;
  buffer->data[buffer->length++] = '\n';
}

static void free_output(void *p) {
  output_buffer *buffer = p;
  free(buffer->data); free(buffer);
}

static void finalize_library(void *p) {
  lean_hegel_library *h = p;
  if (h->library) dlclose(h->library);
  free(h);
}

static void finalize_handle(void *p) {
  lean_hegel_handle *h = p;
  if (h->value && h->free_value) h->free_value(NULL, h->value);
  if (h->auxiliary && h->free_auxiliary) h->free_auxiliary(h->auxiliary);
  lean_dec(h->library);
  free(h);
}

static void finalize_context(void *p) {
  lean_hegel_context *h = p;
  if (h->value) h->free_context(h->value);
  lean_dec(h->library);
  free(h);
}

static lean_external_class *library_class(void) {
  static lean_external_class *c;
  if (!c) c = lean_register_external_class(finalize_library, NULL);
  return c;
}

static lean_external_class *handle_class(void) {
  static lean_external_class *c;
  if (!c) c = lean_register_external_class(finalize_handle, NULL);
  return c;
}

static lean_external_class *context_class(void) {
  static lean_external_class *c;
  if (!c) c = lean_register_external_class(finalize_context, NULL);
  return c;
}

static lean_object *io_error(const char *message) {
  return lean_io_result_mk_error(lean_mk_io_user_error(
      lean_mk_string(message ? message : "unknown libhegel error")));
}

static void *library_ptr(lean_object *library) {
  return ((lean_hegel_library *)lean_get_external_data(library))->library;
}

static void *symbol(lean_object *library, const char *name) {
  return dlsym(library_ptr(library), name);
}

static lean_object *result_error(lean_hegel_context *ctx, hegel_result_t result) {
  const char *message = ctx->last_error(ctx->value);
  if (!message || !message[0]) {
    if (result == -1) message = "libhegel stopped the test after exhausting its choice budget";
    else if (result == -2) message = "libhegel rejected the current test case";
    else message = "libhegel call failed";
  }
  size_t size = strlen(message) + 48;
  char *tagged = malloc(size);
  if (!tagged) return io_error("out of memory while reporting a libhegel error");
  snprintf(tagged, size, "HEGEL_RESULT:%d:%s", result, message);
  lean_object *error = io_error(tagged);
  free(tagged);
  return error;
}

static lean_object *new_handle(lean_object *library, void *value,
                               hegel_result_t (*free_value)(void *, void *)) {
  lean_hegel_handle *h = malloc(sizeof(*h));
  if (!h) return NULL;
  h->value = value;
  h->library = library;
  h->free_value = free_value;
  h->auxiliary = NULL;
  h->free_auxiliary = NULL;
  lean_inc(library);
  return lean_alloc_external(handle_class(), h);
}

LEAN_EXPORT lean_object *lean_hegel_load(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  dlerror();
  void *lib = dlopen(lean_string_cstr(path), RTLD_NOW | RTLD_LOCAL);
  if (!lib) return io_error(dlerror());
  lean_hegel_library *h = malloc(sizeof(*h));
  h->library = lib;
  return lean_io_result_mk_ok(lean_alloc_external(library_class(), h));
}

LEAN_EXPORT lean_object *lean_hegel_version(b_lean_obj_arg library, lean_obj_arg world) {
  (void)world;
  hegel_result_t (*version)(void *, const char **) = symbol(library, "hegel_version");
  if (!version) return io_error("libhegel does not export hegel_version");
  const char *out = NULL;
  if (version(NULL, &out) != 0 || !out) return io_error("hegel_version failed");
  return lean_io_result_mk_ok(lean_mk_string(out));
}

LEAN_EXPORT lean_object *lean_hegel_context_new(b_lean_obj_arg library, lean_obj_arg world) {
  (void)world;
  void *(*create)(void) = symbol(library, "hegel_context_new");
  hegel_result_t (*destroy)(void *) = symbol(library, "hegel_context_free");
  const char *(*last_error)(const void *) = symbol(library, "hegel_context_last_error");
  if (!create || !destroy || !last_error) return io_error("libhegel context ABI is incomplete");
  lean_hegel_context *h = malloc(sizeof(*h));
  h->value = create(); h->library = (lean_object *)library;
  h->free_context = destroy; h->last_error = last_error;
  if (!h->value) { free(h); return io_error("hegel_context_new returned NULL"); }
  lean_inc(library);
  return lean_io_result_mk_ok(lean_alloc_external(context_class(), h));
}

LEAN_EXPORT lean_object *lean_hegel_context_last_error(b_lean_obj_arg context, lean_obj_arg world) {
  (void)world;
  lean_hegel_context *h = lean_get_external_data(context);
  const char *message = h->last_error(h->value);
  return lean_io_result_mk_ok(lean_mk_string(message ? message : ""));
}

LEAN_EXPORT lean_object *lean_hegel_settings_new(b_lean_obj_arg context, lean_obj_arg world) {
  (void)world;
  lean_hegel_context *ctx = lean_get_external_data(context);
  hegel_result_t (*create)(void *, void **) = symbol(ctx->library, "hegel_settings_new");
  hegel_result_t (*destroy)(void *, void *) = symbol(ctx->library, "hegel_settings_free");
  if (!create || !destroy) return io_error("libhegel settings ABI is incomplete");
  void *out = NULL; hegel_result_t r = create(ctx->value, &out);
  if (r != 0) return result_error(ctx, r);
  lean_object *handle = new_handle(ctx->library, out, destroy);
  if (!handle) { destroy(NULL, out); return io_error("out of memory"); }
  return lean_io_result_mk_ok(handle);
}

#define SETTINGS_SETTER(NAME, SYMBOL, CTYPE, UNBOX) \
LEAN_EXPORT lean_object *NAME(b_lean_obj_arg context, b_lean_obj_arg settings, \
                              CTYPE value, lean_obj_arg world) { \
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context); \
  lean_hegel_handle *s = lean_get_external_data(settings); \
  hegel_result_t (*fn)(void *, void *, CTYPE) = symbol(ctx->library, SYMBOL); \
  if (!fn) return io_error("libhegel settings setter is missing"); \
  hegel_result_t r = fn(ctx->value, s->value, UNBOX); \
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r); \
}

SETTINGS_SETTER(lean_hegel_settings_set_mode, "hegel_settings_set_mode", uint32_t, value)
SETTINGS_SETTER(lean_hegel_settings_set_test_cases, "hegel_settings_set_test_cases", uint64_t, value)
SETTINGS_SETTER(lean_hegel_settings_set_verbosity, "hegel_settings_set_verbosity", uint32_t, value)
SETTINGS_SETTER(lean_hegel_settings_set_backend, "hegel_settings_set_backend", uint32_t, value)
SETTINGS_SETTER(lean_hegel_settings_set_phases, "hegel_settings_set_phases", uint32_t, value)
SETTINGS_SETTER(lean_hegel_settings_set_suppress_health_checks, "hegel_settings_set_suppress_health_check", uint32_t, value)
SETTINGS_SETTER(lean_hegel_settings_set_derandomize, "hegel_settings_set_derandomize", uint8_t, value != 0)
SETTINGS_SETTER(lean_hegel_settings_set_report_multiple_failures, "hegel_settings_set_report_multiple_failures", uint8_t, value != 0)

LEAN_EXPORT lean_object *lean_hegel_settings_set_seed(b_lean_obj_arg context,
    b_lean_obj_arg settings, uint64_t seed, uint8_t has_seed, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *s = lean_get_external_data(settings);
  hegel_result_t (*fn)(void *, void *, uint64_t, bool) =
      symbol(ctx->library, "hegel_settings_set_seed");
  if (!fn) return io_error("libhegel seed setter is missing");
  hegel_result_t r = fn(ctx->value, s->value, seed, has_seed != 0);
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r);
}

static lean_object *settings_string(lean_object *context, lean_object *settings,
                                    lean_object *value, const char *name) {
  lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *s = lean_get_external_data(settings);
  hegel_result_t (*fn)(void *, void *, const char *) = symbol(ctx->library, name);
  if (!fn) return io_error("libhegel string settings setter is missing");
  const char *text = lean_string_cstr(value);
  hegel_result_t r = fn(ctx->value, s->value, text);
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_settings_set_database(b_lean_obj_arg context,
    b_lean_obj_arg settings, b_lean_obj_arg value, lean_obj_arg world) {
  (void)world; return settings_string(context, settings, value, "hegel_settings_set_database");
}

LEAN_EXPORT lean_object *lean_hegel_settings_set_database_key(b_lean_obj_arg context,
    b_lean_obj_arg settings, b_lean_obj_arg value, lean_obj_arg world) {
  (void)world; return settings_string(context, settings, value, "hegel_settings_set_database_key");
}

LEAN_EXPORT lean_object *lean_hegel_run_start(b_lean_obj_arg context,
    b_lean_obj_arg settings, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *s = lean_get_external_data(settings);
  hegel_result_t (*start)(void *, const void *, hegel_output_callback, void *, void **) =
      symbol(ctx->library, "hegel_run_start");
  hegel_result_t (*destroy)(void *, void *) = symbol(ctx->library, "hegel_run_free");
  if (!start || !destroy) return io_error("libhegel run ABI is incomplete");
  output_buffer *buffer = calloc(1, sizeof(*buffer));
  if (!buffer) return io_error("out of memory");
  void *out = NULL; hegel_result_t r = start(ctx->value, s->value,
      capture_output, buffer, &out);
  if (r != 0) { free_output(buffer); return result_error(ctx, r); }
  lean_object *object = new_handle(ctx->library, out, destroy);
  lean_hegel_handle *handle = lean_get_external_data(object);
  handle->auxiliary = buffer; handle->free_auxiliary = free_output;
  return lean_io_result_mk_ok(object);
}

LEAN_EXPORT lean_object *lean_hegel_run_output(b_lean_obj_arg run, lean_obj_arg world) {
  (void)world;
  lean_hegel_handle *handle = lean_get_external_data(run);
  output_buffer *buffer = handle->auxiliary;
  if (!buffer || !buffer->data) return lean_io_result_mk_ok(lean_mk_string(""));
  return lean_io_result_mk_ok(lean_mk_string_from_bytes(buffer->data, buffer->length));
}

LEAN_EXPORT lean_object *lean_hegel_next_test_case(b_lean_obj_arg context,
    b_lean_obj_arg run, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *rh = lean_get_external_data(run);
  hegel_result_t (*next)(void *, void *, void **) = symbol(ctx->library, "hegel_next_test_case");
  hegel_result_t (*destroy)(void *, void *) = symbol(ctx->library, "hegel_test_case_free");
  if (!next || !destroy) return io_error("libhegel test-case ABI is incomplete");
  void *out = NULL; hegel_result_t r = next(ctx->value, rh->value, &out);
  if (r != 0) return result_error(ctx, r);
  if (!out) return lean_io_result_mk_ok(lean_box(0));
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, new_handle(ctx->library, out, destroy));
  return lean_io_result_mk_ok(some);
}

LEAN_EXPORT lean_object *lean_hegel_test_case_clone(b_lean_obj_arg context,
    b_lean_obj_arg test_case, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*clone)(void *, const void *, void **) =
      symbol(ctx->library, "hegel_test_case_clone");
  hegel_result_t (*destroy)(void *, void *) = symbol(ctx->library, "hegel_test_case_free");
  if (!clone || !destroy) return io_error("libhegel test-case clone ABI is incomplete");
  void *out = NULL; hegel_result_t r = clone(ctx->value, tc->value, &out);
  if (r != 0) return result_error(ctx, r);
  return lean_io_result_mk_ok(new_handle(ctx->library, out, destroy));
}

LEAN_EXPORT lean_object *lean_hegel_generate_integer(b_lean_obj_arg context,
    b_lean_obj_arg test_case, int64_t min, int64_t max, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*generate)(void *, void *, int64_t, int64_t, int64_t *) =
      symbol(ctx->library, "hegel_generate_integer");
  if (!generate) return io_error("libhegel integer generator is missing");
  int64_t out = 0; hegel_result_t r = generate(ctx->value, tc->value, min, max, &out);
  /* Lean's Int64 is represented by the same boxed 64 bits as UInt64. */
  return r == 0 ? lean_io_result_mk_ok(lean_box_uint64((uint64_t)out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_generate_integer_big(b_lean_obj_arg context,
    b_lean_obj_arg test_case, b_lean_obj_arg min, b_lean_obj_arg max,
    lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*generate)(void *, void *, const uint8_t *, size_t,
      const uint8_t *, size_t, uint8_t *, size_t, size_t *) =
      symbol(ctx->library, "hegel_generate_integer_big");
  if (!generate) return io_error("libhegel arbitrary integer generator is missing");
  size_t min_len = lean_sarray_size(min), max_len = lean_sarray_size(max);
  size_t capacity = min_len > max_len ? min_len : max_len;
  uint8_t *out = malloc(capacity ? capacity : 1);
  if (!out) return io_error("out of memory");
  size_t out_len = 0;
  hegel_result_t r = generate(ctx->value, tc->value,
      lean_sarray_cptr(min), min_len, lean_sarray_cptr(max), max_len,
      out, capacity, &out_len);
  if (r != 0) { free(out); return result_error(ctx, r); }
  lean_object *bytes = fixed_bytes(out, out_len);
  free(out);
  return lean_io_result_mk_ok(bytes);
}

LEAN_EXPORT lean_object *lean_hegel_generate_boolean(b_lean_obj_arg context,
    b_lean_obj_arg test_case, double probability, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*generate)(void *, void *, double, bool, bool, bool *) =
      symbol(ctx->library, "hegel_generate_boolean");
  if (!generate) return io_error("libhegel boolean generator is missing");
  bool out = false; hegel_result_t r = generate(ctx->value, tc->value, probability, false, false, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box(out ? 1 : 0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_generate_float(b_lean_obj_arg context,
    b_lean_obj_arg test_case, double min, double max, uint8_t allow_nan,
    uint8_t allow_infinity, uint8_t exclude_min, uint8_t exclude_max,
    double smallest_nonzero, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*generate)(void *, void *, uint32_t, double, double,
      bool, bool, bool, bool, double, double *) = symbol(ctx->library, "hegel_generate_float");
  if (!generate) return io_error("libhegel float generator is missing");
  double out = 0.0;
  hegel_result_t r = generate(ctx->value, tc->value, 64, min, max,
      allow_nan != 0, allow_infinity != 0, exclude_min != 0, exclude_max != 0,
      smallest_nonzero, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box_float(out)) : result_error(ctx, r);
}

typedef struct { uint8_t *data; size_t len; } hegel_bytes_result;

LEAN_EXPORT lean_object *lean_hegel_generate_bytes(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint64_t min, uint64_t max, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*generate)(void *, void *, uint64_t, uint64_t, hegel_bytes_result *) =
      symbol(ctx->library, "hegel_generate_bytes");
  hegel_result_t (*release)(void *, hegel_bytes_result *) =
      symbol(ctx->library, "hegel_generate_bytes_result_free");
  if (!generate || !release) return io_error("libhegel byte generator ABI is incomplete");
  hegel_bytes_result out = {NULL, 0};
  hegel_result_t r = generate(ctx->value, tc->value, min, max, &out);
  if (r != 0) return result_error(ctx, r);
  lean_object *bytes = lean_alloc_sarray(1, out.len, out.len);
  if (out.len) memcpy(lean_sarray_cptr(bytes), out.data, out.len);
  release(ctx->value, &out);
  return lean_io_result_mk_ok(bytes);
}

typedef struct { char *data; size_t len; } hegel_string_result;

LEAN_EXPORT lean_object *lean_hegel_generate_text(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint64_t min, uint64_t max, uint8_t ascii_only,
    lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*make)(void *, uint64_t, uint64_t, const char *, uint32_t, uint32_t,
      const char *const *, size_t, const char *const *, size_t,
      const uint8_t *, size_t, const uint8_t *, size_t, void **) =
      symbol(ctx->library, "hegel_string_generator_text");
  hegel_result_t (*free_generator)(void *, void *) =
      symbol(ctx->library, "hegel_string_generator_free");
  hegel_result_t (*generate)(void *, void *, const void *, hegel_string_result *) =
      symbol(ctx->library, "hegel_generate_string");
  hegel_result_t (*free_result)(void *, hegel_string_result *) =
      symbol(ctx->library, "hegel_generate_string_result_free");
  if (!make || !free_generator || !generate || !free_result)
    return io_error("libhegel text generator ABI is incomplete");
  void *generator = NULL;
  hegel_result_t r = make(ctx->value, min, max, ascii_only ? "ascii" : "utf-8",
      0, UINT32_MAX, NULL, 0, NULL, 0, NULL, 0, NULL, 0, &generator);
  if (r != 0) return result_error(ctx, r);
  hegel_string_result out = {NULL, 0};
  r = generate(ctx->value, tc->value, generator, &out);
  if (r != 0) {
    lean_object *error = result_error(ctx, r);
    free_generator(NULL, generator);
    return error;
  }
  lean_object *string = lean_mk_string_from_bytes(out.data, out.len);
  free_result(NULL, &out);
  free_generator(NULL, generator);
  return lean_io_result_mk_ok(string);
}

LEAN_EXPORT lean_object *lean_hegel_generate_formatted_string(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint32_t kind, b_lean_obj_arg parameter,
    uint64_t number, uint8_t flag, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*free_generator)(void *, void *) =
      symbol(ctx->library, "hegel_string_generator_free");
  hegel_result_t (*generate)(void *, void *, const void *, hegel_string_result *) =
      symbol(ctx->library, "hegel_generate_string");
  hegel_result_t (*free_result)(void *, hegel_string_result *) =
      symbol(ctx->library, "hegel_generate_string_result_free");
  if (!free_generator || !generate || !free_result)
    return io_error("libhegel formatted-string ABI is incomplete");

  void *generator = NULL;
  hegel_result_t r;
  if (kind == 0 || kind == 1) {
    const char *name = kind == 0 ? "hegel_string_generator_email" : "hegel_string_generator_url";
    hegel_result_t (*make)(void *, void **) = symbol(ctx->library, name);
    if (!make) return io_error("libhegel formatted-string constructor is missing");
    r = make(ctx->value, &generator);
  } else if (kind == 2) {
    hegel_result_t (*make)(void *, uint64_t, void **) =
        symbol(ctx->library, "hegel_string_generator_domain");
    if (!make) return io_error("libhegel domain constructor is missing");
    r = make(ctx->value, number, &generator);
  } else if (kind == 3) {
    hegel_result_t (*make)(void *, const char *, bool, const void *, void **) =
        symbol(ctx->library, "hegel_string_generator_regex");
    if (!make) return io_error("libhegel regex constructor is missing");
    r = make(ctx->value, lean_string_cstr(parameter), flag != 0, NULL, &generator);
  } else {
    return io_error("unknown formatted-string generator kind");
  }
  if (r != 0) return result_error(ctx, r);

  hegel_string_result out = {NULL, 0};
  r = generate(ctx->value, tc->value, generator, &out);
  if (r != 0) {
    lean_object *error = result_error(ctx, r);
    free_generator(NULL, generator);
    return error;
  }
  lean_object *string = lean_mk_string_from_bytes(out.data, out.len);
  free_result(NULL, &out);
  free_generator(NULL, generator);
  return lean_io_result_mk_ok(string);
}

typedef struct { int32_t year; uint8_t month; uint8_t day; } hegel_date_value;
typedef struct { uint8_t hour; uint8_t minute; uint8_t second; uint32_t microsecond; } hegel_time_value;
typedef struct { hegel_date_value date; hegel_time_value time; } hegel_datetime_value;

static lean_object *box_date(hegel_date_value value) {
  uint8_t out[6];
  uint32_t year = (uint32_t)value.year;
  out[0] = year; out[1] = year >> 8; out[2] = year >> 16; out[3] = year >> 24;
  out[4] = value.month; out[5] = value.day;
  return fixed_bytes(out, sizeof(out));
}

static lean_object *box_time(hegel_time_value value) {
  uint8_t out[7] = {value.hour, value.minute, value.second,
      value.microsecond, value.microsecond >> 8, value.microsecond >> 16,
      value.microsecond >> 24};
  return fixed_bytes(out, sizeof(out));
}

LEAN_EXPORT lean_object *lean_hegel_generate_date(b_lean_obj_arg context,
    b_lean_obj_arg test_case, int32_t min_year, uint8_t min_month, uint8_t min_day,
    int32_t max_year, uint8_t max_month, uint8_t max_day, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, hegel_date_value, hegel_date_value, hegel_date_value *) =
      symbol(ctx->library, "hegel_generate_date");
  if (!fn) return io_error("libhegel date generator is missing");
  hegel_date_value min = {min_year, min_month, min_day};
  hegel_date_value max = {max_year, max_month, max_day};
  hegel_date_value out;
  hegel_result_t r = fn(ctx->value, tc->value, min, max, &out);
  return r == 0 ? lean_io_result_mk_ok(box_date(out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_generate_time(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint8_t min_hour, uint8_t min_minute, uint8_t min_second,
    uint32_t min_microsecond, uint8_t max_hour, uint8_t max_minute, uint8_t max_second,
    uint32_t max_microsecond, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, hegel_time_value, hegel_time_value, hegel_time_value *) =
      symbol(ctx->library, "hegel_generate_time");
  if (!fn) return io_error("libhegel time generator is missing");
  hegel_time_value min = {min_hour, min_minute, min_second, min_microsecond};
  hegel_time_value max = {max_hour, max_minute, max_second, max_microsecond};
  hegel_time_value out;
  hegel_result_t r = fn(ctx->value, tc->value, min, max, &out);
  return r == 0 ? lean_io_result_mk_ok(box_time(out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_generate_datetime(b_lean_obj_arg context,
    b_lean_obj_arg test_case,
    int32_t min_year, uint8_t min_month, uint8_t min_day, uint8_t min_hour,
    uint8_t min_minute, uint8_t min_second, uint32_t min_microsecond,
    int32_t max_year, uint8_t max_month, uint8_t max_day, uint8_t max_hour,
    uint8_t max_minute, uint8_t max_second, uint32_t max_microsecond,
    lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, hegel_datetime_value, hegel_datetime_value,
      hegel_datetime_value *) = symbol(ctx->library, "hegel_generate_datetime");
  if (!fn) return io_error("libhegel datetime generator is missing");
  hegel_datetime_value min = {{min_year, min_month, min_day},
      {min_hour, min_minute, min_second, min_microsecond}};
  hegel_datetime_value max = {{max_year, max_month, max_day},
      {max_hour, max_minute, max_second, max_microsecond}};
  hegel_datetime_value out;
  hegel_result_t r = fn(ctx->value, tc->value, min, max, &out);
  if (r != 0) return result_error(ctx, r);
  uint8_t bytes[13];
  uint32_t year = (uint32_t)out.date.year;
  bytes[0] = year; bytes[1] = year >> 8; bytes[2] = year >> 16; bytes[3] = year >> 24;
  bytes[4] = out.date.month; bytes[5] = out.date.day;
  bytes[6] = out.time.hour; bytes[7] = out.time.minute; bytes[8] = out.time.second;
  bytes[9] = out.time.microsecond; bytes[10] = out.time.microsecond >> 8;
  bytes[11] = out.time.microsecond >> 16; bytes[12] = out.time.microsecond >> 24;
  return lean_io_result_mk_ok(fixed_bytes(bytes, sizeof(bytes)));
}

static lean_object *fixed_bytes(const uint8_t *data, size_t len) {
  lean_object *bytes = lean_alloc_sarray(1, len, len);
  if (len) memcpy(lean_sarray_cptr(bytes), data, len);
  return bytes;
}

LEAN_EXPORT lean_object *lean_hegel_generate_uuid(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint8_t version, uint8_t has_version, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, uint8_t, bool, uint8_t *) =
      symbol(ctx->library, "hegel_generate_uuid");
  if (!fn) return io_error("libhegel UUID generator is missing");
  uint8_t out[16]; hegel_result_t r = fn(ctx->value, tc->value, version, has_version != 0, out);
  return r == 0 ? lean_io_result_mk_ok(fixed_bytes(out, 16)) : result_error(ctx, r);
}

static lean_object *generate_ip(lean_object *context, lean_object *test_case,
                                const char *name, size_t len) {
  lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, uint8_t *) = symbol(ctx->library, name);
  if (!fn) return io_error("libhegel IP-address generator is missing");
  uint8_t out[16]; hegel_result_t r = fn(ctx->value, tc->value, out);
  return r == 0 ? lean_io_result_mk_ok(fixed_bytes(out, len)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_generate_ipv4(b_lean_obj_arg context,
    b_lean_obj_arg test_case, lean_obj_arg world) {
  (void)world; return generate_ip(context, test_case, "hegel_generate_ipv4", 4);
}

LEAN_EXPORT lean_object *lean_hegel_generate_ipv6(b_lean_obj_arg context,
    b_lean_obj_arg test_case, lean_obj_arg world) {
  (void)world; return generate_ip(context, test_case, "hegel_generate_ipv6", 16);
}

LEAN_EXPORT lean_object *lean_hegel_start_span(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint64_t label, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, uint64_t) = symbol(ctx->library, "hegel_start_span");
  if (!fn) return io_error("libhegel span ABI is missing");
  hegel_result_t r = fn(ctx->value, tc->value, label);
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_stop_span(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint8_t discard, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, bool) = symbol(ctx->library, "hegel_stop_span");
  if (!fn) return io_error("libhegel span ABI is missing");
  hegel_result_t r = fn(ctx->value, tc->value, discard != 0);
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_new_collection(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint64_t min, uint64_t max, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, uint64_t, uint64_t, int64_t *) =
      symbol(ctx->library, "hegel_new_collection");
  if (!fn) return io_error("libhegel collection ABI is missing");
  int64_t out = 0; hegel_result_t r = fn(ctx->value, tc->value, min, max, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box_uint64((uint64_t)out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_collection_more(b_lean_obj_arg context,
    b_lean_obj_arg test_case, int64_t id, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, int64_t, bool *) = symbol(ctx->library, "hegel_collection_more");
  if (!fn) return io_error("libhegel collection ABI is missing");
  bool out = false; hegel_result_t r = fn(ctx->value, tc->value, id, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box(out ? 1 : 0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_collection_reject(b_lean_obj_arg context,
    b_lean_obj_arg test_case, int64_t id, b_lean_obj_arg reason, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, int64_t, const char *) =
      symbol(ctx->library, "hegel_collection_reject");
  if (!fn) return io_error("libhegel collection rejection ABI is missing");
  const char *reason_c = lean_string_cstr(reason);
  hegel_result_t r = fn(ctx->value, tc->value, id, reason_c[0] ? reason_c : NULL);
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_target(b_lean_obj_arg context,
    b_lean_obj_arg test_case, double value, b_lean_obj_arg label, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, double, const char *) = symbol(ctx->library, "hegel_target");
  if (!fn) return io_error("libhegel targeting ABI is missing");
  hegel_result_t r = fn(ctx->value, tc->value, value, lean_string_cstr(label));
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_new_pool(b_lean_obj_arg context,
    b_lean_obj_arg test_case, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, int64_t *) = symbol(ctx->library, "hegel_new_pool");
  if (!fn) return io_error("libhegel pool ABI is missing");
  int64_t out = 0; hegel_result_t r = fn(ctx->value, tc->value, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box_uint64((uint64_t)out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_pool_add(b_lean_obj_arg context,
    b_lean_obj_arg test_case, int64_t pool, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, int64_t, int64_t *) = symbol(ctx->library, "hegel_pool_add");
  if (!fn) return io_error("libhegel pool ABI is missing");
  int64_t out = 0; hegel_result_t r = fn(ctx->value, tc->value, pool, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box_uint64((uint64_t)out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_pool_generate(b_lean_obj_arg context,
    b_lean_obj_arg test_case, int64_t pool, uint8_t consume, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, int64_t, bool, int64_t *) =
      symbol(ctx->library, "hegel_pool_generate");
  if (!fn) return io_error("libhegel pool ABI is missing");
  int64_t out = 0; hegel_result_t r = fn(ctx->value, tc->value, pool, consume != 0, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box_uint64((uint64_t)out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_new_state_machine(b_lean_obj_arg context,
    b_lean_obj_arg test_case, b_lean_obj_arg rules, b_lean_obj_arg invariants,
    lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, const char *const *, size_t,
      const char *const *, size_t, int64_t *) = symbol(ctx->library, "hegel_new_state_machine");
  if (!fn) return io_error("libhegel state-machine ABI is missing");
  size_t rule_count = lean_array_size(rules);
  size_t invariant_count = lean_array_size(invariants);
  const char **rule_names = rule_count ? malloc(rule_count * sizeof(char *)) : NULL;
  const char **invariant_names = invariant_count ? malloc(invariant_count * sizeof(char *)) : NULL;
  if ((rule_count && !rule_names) || (invariant_count && !invariant_names)) {
    free(rule_names); free(invariant_names); return io_error("out of memory");
  }
  for (size_t i = 0; i < rule_count; ++i)
    rule_names[i] = lean_string_cstr(lean_array_uget(rules, i));
  for (size_t i = 0; i < invariant_count; ++i)
    invariant_names[i] = lean_string_cstr(lean_array_uget(invariants, i));
  int64_t out = 0;
  hegel_result_t r = fn(ctx->value, tc->value, rule_names, rule_count,
      invariant_names, invariant_count, &out);
  free(rule_names); free(invariant_names);
  return r == 0 ? lean_io_result_mk_ok(lean_box_uint64((uint64_t)out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_state_machine_next_rule(b_lean_obj_arg context,
    b_lean_obj_arg test_case, int64_t machine, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*fn)(void *, void *, int64_t, int64_t *) =
      symbol(ctx->library, "hegel_state_machine_next_rule");
  if (!fn) return io_error("libhegel state-machine ABI is missing");
  int64_t out = 0; hegel_result_t r = fn(ctx->value, tc->value, machine, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box_uint64((uint64_t)out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_mark_complete(b_lean_obj_arg context,
    b_lean_obj_arg test_case, uint32_t status, b_lean_obj_arg origin, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *tc = lean_get_external_data(test_case);
  hegel_result_t (*complete)(void *, void *, uint32_t, const char *) =
      symbol(ctx->library, "hegel_mark_complete");
  if (!complete) return io_error("libhegel completion ABI is missing");
  const char *origin_c = lean_string_cstr(origin);
  hegel_result_t r = complete(ctx->value, tc->value, status, origin_c[0] ? origin_c : NULL);
  return r == 0 ? lean_io_result_mk_ok(lean_box(0)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_run_result(b_lean_obj_arg context,
    b_lean_obj_arg run, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *rh = lean_get_external_data(run);
  hegel_result_t (*get)(void *, void *, void **) = symbol(ctx->library, "hegel_run_result");
  hegel_result_t (*destroy)(void *, void *) = symbol(ctx->library, "hegel_run_result_free");
  if (!get || !destroy) return io_error("libhegel result ABI is incomplete");
  void *out = NULL; hegel_result_t r = get(ctx->value, rh->value, &out);
  if (r != 0) return result_error(ctx, r);
  return lean_io_result_mk_ok(new_handle(ctx->library, out, destroy));
}

LEAN_EXPORT lean_object *lean_hegel_run_result_status(b_lean_obj_arg context,
    b_lean_obj_arg result, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *rh = lean_get_external_data(result);
  hegel_result_t (*get)(void *, const void *, uint32_t *) = symbol(ctx->library, "hegel_run_result_status");
  uint32_t out = 0; hegel_result_t r = get(ctx->value, rh->value, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box(out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_run_result_failure_count(b_lean_obj_arg context,
    b_lean_obj_arg result, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *rh = lean_get_external_data(result);
  hegel_result_t (*get)(void *, const void *, size_t *) = symbol(ctx->library, "hegel_run_result_failure_count");
  size_t out = 0; hegel_result_t r = get(ctx->value, rh->value, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_box_usize(out)) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_run_result_error(b_lean_obj_arg context,
    b_lean_obj_arg result, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *rh = lean_get_external_data(result);
  hegel_result_t (*get)(void *, const void *, const char **) =
      symbol(ctx->library, "hegel_run_result_error");
  if (!get) return io_error("libhegel result-error accessor is missing");
  const char *out = NULL; hegel_result_t r = get(ctx->value, rh->value, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_mk_string(out ? out : "")) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_run_result_failure(b_lean_obj_arg context,
    b_lean_obj_arg result, size_t index, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *rh = lean_get_external_data(result);
  hegel_result_t (*get)(void *, const void *, size_t, void **) =
      symbol(ctx->library, "hegel_run_result_failure");
  hegel_result_t (*destroy)(void *, void *) = symbol(ctx->library, "hegel_failure_free");
  if (!get || !destroy) return io_error("libhegel failure ABI is incomplete");
  void *out = NULL; hegel_result_t r = get(ctx->value, rh->value, index, &out);
  if (r != 0) return result_error(ctx, r);
  return lean_io_result_mk_ok(new_handle(ctx->library, out, destroy));
}

static lean_object *failure_string(b_lean_obj_arg context, b_lean_obj_arg failure,
                                   const char *symbol_name) {
  lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *fh = lean_get_external_data(failure);
  hegel_result_t (*get)(void *, const void *, const char **) = symbol(ctx->library, symbol_name);
  if (!get) return io_error("libhegel failure accessor is missing");
  const char *out = NULL; hegel_result_t r = get(ctx->value, fh->value, &out);
  return r == 0 ? lean_io_result_mk_ok(lean_mk_string(out ? out : "")) : result_error(ctx, r);
}

LEAN_EXPORT lean_object *lean_hegel_failure_origin(b_lean_obj_arg context,
    b_lean_obj_arg failure, lean_obj_arg world) {
  (void)world; return failure_string(context, failure, "hegel_failure_origin");
}

LEAN_EXPORT lean_object *lean_hegel_failure_blob(b_lean_obj_arg context,
    b_lean_obj_arg failure, lean_obj_arg world) {
  (void)world; return failure_string(context, failure, "hegel_failure_reproduction_blob");
}

LEAN_EXPORT lean_object *lean_hegel_test_case_from_blob(b_lean_obj_arg context,
    b_lean_obj_arg settings, b_lean_obj_arg blob, lean_obj_arg world) {
  (void)world; lean_hegel_context *ctx = lean_get_external_data(context);
  lean_hegel_handle *sh = lean_get_external_data(settings);
  hegel_result_t (*create)(void *, const void *, const char *, void *, void *, void **) =
      symbol(ctx->library, "hegel_test_case_from_blob");
  hegel_result_t (*destroy)(void *, void *) = symbol(ctx->library, "hegel_test_case_free");
  if (!create || !destroy) return io_error("libhegel replay ABI is incomplete");
  void *out = NULL;
  hegel_result_t r = create(ctx->value, sh->value, lean_string_cstr(blob), NULL, NULL, &out);
  if (r != 0) return result_error(ctx, r);
  return lean_io_result_mk_ok(new_handle(ctx->library, out, destroy));
}
