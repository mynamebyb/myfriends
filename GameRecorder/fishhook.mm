// Copyright (c) 2013, Facebook, Inc.
// MIT License
//  .mm 版，修 C++ 严格性错误
#include "fishhook.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifndef LC_SEGMENT_ARCH_DEPENDENT
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#endif

struct rebindings_entry {
  struct rebinding *rebindings;
  size_t rebindings_nel;
  struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head;

static int prepend_rebindings(struct rebindings_entry **rebindings_head,
                              struct rebinding rebindings[],
                              size_t nel) {
  struct rebindings_entry *new_entry =
      (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
  if (!new_entry) return -1;
  new_entry->rebindings =
      (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
  if (!new_entry->rebindings) { free(new_entry); return -1; }
  memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
  new_entry->rebindings_nel = nel;
  new_entry->next = *rebindings_head;
  *rebindings_head = new_entry;
  return 0;
}

static void perform_rebinding_with_slide(struct rebindings_entry *rebindings,
                                         intptr_t slide,
                                         struct nlist *symtab,
                                         char *strtab,
                                         uint32_t *indirect_symtab) {
  uint32_t *indirect_symbol_indices = indirect_symtab;
  void *const *indirect_symbol_bindings = (void *const *)indirect_symtab;
  for (struct rebindings_entry *cur = rebindings; cur; cur = cur->next) {
    for (uint32_t i = 0; i < cur->rebindings_nel; i++) {
      uint32_t symtab_index = indirect_symbol_indices[i];
      if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL)
        continue;
      uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
      char *symbol_name = strtab + strtab_offset;
      if ((symtab[symtab_index].n_type & N_STAB) &&
          strcmp(symbol_name + 1, cur->rebindings[i].name) == 0) {
        cur->rebindings[i].replaced = (void **)&indirect_symbol_bindings[i];
        *cur->rebindings[i].replaced =
            (void *)((char *)cur->rebindings[i].replacement + slide);
      }
    }
  }
}

static void rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
  Dl_info info;
  if (dladdr(header, &info) == 0) return;

  struct segment_command *cur_seg_cmd = NULL;
  uint32_t segment_count = 0;
  struct segment_command *linkedit_segment = NULL;
  uint32_t symtab_cmd_offset = 0;
  uint32_t dysymtab_cmd_offset = 0;

  if (header->magic == MH_MAGIC) {
    struct mach_header *header32 = (struct mach_header *)header;
    cur_seg_cmd = (struct segment_command *)((char *)header32 + sizeof(struct mach_header));
    segment_count = header32->ncmds;
  } else if (header->magic == MH_MAGIC_64) {
    struct mach_header_64 *header64 = (struct mach_header_64 *)header;
    cur_seg_cmd = (struct segment_command *)((char *)header64 + sizeof(struct mach_header_64));
    segment_count = header64->ncmds;
  } else {
    return;
  }

  for (uint32_t i = 0; i < segment_count; i++) {
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT &&
        strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
      linkedit_segment = cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
      symtab_cmd_offset = (uint32_t)((char *)cur_seg_cmd - (char *)header);
    } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
      dysymtab_cmd_offset = (uint32_t)((char *)cur_seg_cmd - (char *)header);
    }
    cur_seg_cmd = (struct segment_command *)((char *)cur_seg_cmd + cur_seg_cmd->cmdsize);
  }

  if (!symtab_cmd_offset || !dysymtab_cmd_offset || !linkedit_segment) return;

  struct symtab_command *symtab_cmd =
      (struct symtab_command *)((char *)header + symtab_cmd_offset);
  struct dysymtab_command *dysymtab_cmd =
      (struct dysymtab_command *)((char *)header + dysymtab_cmd_offset);

  uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
  struct nlist *symtab = (struct nlist *)(linkedit_base + symtab_cmd->symoff);
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
  uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  perform_rebinding_with_slide(_rebindings_head, slide, symtab, strtab, indirect_symtab);
}

static void _rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
  rebind_symbols_for_image(header, slide);
}

int rebind_symbols_image(void *header, intptr_t slide, struct rebinding rebindings[], size_t rebindings_nel) {
  struct rebindings_entry *rebindings_head = NULL;
  int retval = prepend_rebindings(&rebindings_head, rebindings, rebindings_nel);
  if (retval != 0) return retval;
  struct rebindings_entry *old_head = _rebindings_head;
  _rebindings_head = rebindings_head;
  rebind_symbols_for_image((const struct mach_header *)header, slide);
  _rebindings_head = old_head;
  free(rebindings_head->rebindings);
  free(rebindings_head);
  return retval;
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  int retval = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
  if (retval != 0) return retval;
  static bool did_register = false;
  if (!did_register) {
    _dyld_register_func_for_add_image(_rebind_symbols_for_image);
    did_register = true;
  }
  uint32_t c = _dyld_image_count();
  for (uint32_t i = 0; i < c; i++) {
    rebind_symbols_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
  }
  return retval;
}
