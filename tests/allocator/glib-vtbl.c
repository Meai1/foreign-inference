#include <stdlib.h>

typedef void* gpointer;
typedef size_t gsize;
typedef struct _GMemVTable GMemVTable;

struct _GMemVTable {
  gpointer (*malloc)      (gsize    n_bytes);
  gpointer (*realloc)     (gpointer mem,
      gsize    n_bytes);
  void     (*free)        (gpointer mem);
  /* optional; set to NULL if not used ! */
  gpointer (*calloc)      (gsize    n_blocks,
      gsize    n_block_bytes);
  gpointer (*try_malloc)  (gsize    n_bytes);
  gpointer (*try_realloc) (gpointer mem,
      gsize    n_bytes);
};

static GMemVTable glib_mem_vtable = {
  malloc,
  realloc,
  free,
  calloc,
  malloc,
  realloc,
};

#define G_UNLIKELY(x) x
#define G_LIKELY(x) x

gpointer
g_malloc (gsize n_bytes)
{
  /* if (G_UNLIKELY (!g_mem_initialized)) */
  /*   g_mem_init_nomessage(); */
  if (G_LIKELY (n_bytes))
  {
    gpointer mem;

    mem = glib_mem_vtable.malloc (n_bytes);
    //   TRACE (GLIB_MEM_ALLOC((void*) mem, (unsigned int) n_bytes, 0, 0));
    if (mem)
      return mem;

    /* g_error ("%s: failed to allocate %"G_GSIZE_FORMAT" bytes", */
    /*     G_STRLOC, n_bytes); */
  }

//  TRACE(GLIB_MEM_ALLOC((void*) NULL, (int) n_bytes, 0, 0));

  return NULL;
}
