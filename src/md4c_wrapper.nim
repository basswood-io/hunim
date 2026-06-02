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
#include <string.h>

typedef struct {
  char* data;
  int len;
  int cap;
} CStringBuilder;

static void output_callback(const char* text, unsigned int size, void* userdata) {
  CStringBuilder* builder = (CStringBuilder*)userdata;
  if (builder->len + size > builder->cap) {
    builder->cap = (builder->len + size) * 2;
    builder->data = realloc(builder->data, builder->cap);
  }
  memcpy(builder->data + builder->len, text, size);
  builder->len += size;
}

int nim_md_html_wrapper(const char* input, unsigned int input_size, unsigned int flags, char** output, int* output_size) {
  CStringBuilder builder;
  builder.data = malloc(input_size * 2);
  builder.len = 0;
  builder.cap = input_size * 2;

  int ret = md_html(input, input_size, output_callback, &builder, flags, 0);

  *output = builder.data;
  *output_size = builder.len;

  return ret;
}
""".}

proc nim_md_html_wrapper(input: cstring, input_size: cuint, flags: cuint, output: ptr cstring, output_size: ptr cint): cint {.importc, nodecl.}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}

proc markdown*(input: string): string {.gcsafe.} =
  ## Convert markdown to HTML using md4c
  var output: cstring
  var output_size: cint

  let ret = nim_md_html_wrapper(
    input.cstring,
    input.len.cuint,
    MD_DIALECT_GITHUB,
    addr output,
    addr output_size
  )

  if ret != 0:
    raise newException(ValueError, "Markdown parsing failed")

  result = newString(output_size)
  if output_size > 0:
    copyMem(addr result[0], output, output_size)
  free(output)
