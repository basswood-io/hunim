{.compile: "../lib/md4c/src/md4c.c".}
{.compile: "../lib/md4c/src/md4c-html.c".}
{.compile: "../lib/md4c/src/entity.c".}

const
  MD_FLAG_PERMISSIVEATXHEADERS = 0x0002'u32
  MD_FLAG_PERMISSIVEURLAUTOLINKS = 0x0004'u32
  MD_FLAG_PERMISSIVEEMAILAUTOLINKS = 0x0008'u32
  MD_FLAG_PERMISSIVEWWWAUTOLINKS = 0x0400'u32
  MD_FLAG_TABLES = 0x0100'u32
  MD_FLAG_STRIKETHROUGH = 0x0200'u32
  MD_FLAG_TASKLISTS = 0x0800'u32

  MD_DIALECT_GITHUB = MD_FLAG_PERMISSIVEATXHEADERS or
                      MD_FLAG_PERMISSIVEURLAUTOLINKS or
                      MD_FLAG_PERMISSIVEEMAILAUTOLINKS or
                      MD_FLAG_PERMISSIVEWWWAUTOLINKS or
                      MD_FLAG_TABLES or
                      MD_FLAG_STRIKETHROUGH or
                      MD_FLAG_TASKLISTS

{.emit: """
#include "../lib/md4c/src/md4c-html.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  char* data;
  size_t len;
  size_t cap;
  int failed; /* set on allocation failure; the output is then incomplete */
} CStringBuilder;

static void output_callback(const char* text, unsigned int size, void* userdata) {
  CStringBuilder* builder = (CStringBuilder*)userdata;
  if (builder->failed) {
    return;
  }
  if (size > builder->cap - builder->len) {
    if (builder->len > (SIZE_MAX - size) / 2) {
      builder->failed = 1;
      return;
    }
    size_t new_cap = (builder->len + size) * 2;
    char* grown = realloc(builder->data, new_cap);
    if (grown == NULL) {
      builder->failed = 1;
      return;
    }
    builder->data = grown;
    builder->cap = new_cap;
  }
  memcpy(builder->data + builder->len, text, size);
  builder->len += size;
}

/* Returns 0 on success. On failure, *output may still hold a buffer that the
   caller must free. */
int nim_md_html_wrapper(const char* input, unsigned int input_size, unsigned int flags, char** output, size_t* output_size) {
  CStringBuilder builder;
  builder.cap = (size_t)input_size * 2 + 1;
  builder.len = 0;
  builder.failed = 0;
  builder.data = malloc(builder.cap);

  int ret = -1;
  if (builder.data != NULL) {
    ret = md_html(input, input_size, output_callback, &builder, flags, 0);
    if (builder.failed) {
      ret = -1;
    }
  }

  *output = builder.data;
  *output_size = builder.len;
  return ret;
}
""".}

proc nimMdHtmlWrapper(input: cstring, inputSize: cuint, flags: cuint,
    output: ptr cstring, outputSize: ptr csize_t): cint {.
    importc: "nim_md_html_wrapper", nodecl.}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}

proc markdown*(input: string): string {.gcsafe.} =
  ## Convert markdown to HTML using md4c
  if input.len.uint64 > high(uint32).uint64:
    raise newException(ValueError, "Markdown input too large")

  var output: cstring
  var outputSize: csize_t
  let ret = nimMdHtmlWrapper(input.cstring, input.len.cuint, MD_DIALECT_GITHUB,
      addr output, addr outputSize)
  try:
    if ret != 0:
      raise newException(ValueError, "Markdown parsing failed")
    result = newString(outputSize.int)
    if outputSize > 0:
      copyMem(addr result[0], output, outputSize.int)
  finally:
    free(output)
