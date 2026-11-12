#ifndef CLIPSLOTS_ARCHIVE_SHIM_H
#define CLIPSLOTS_ARCHIVE_SHIM_H

// macOS ships libarchive.2 but recent SDKs omit its headers. Declare only the
// stable public ABI used here; this links the OS library, not a bundled binary.
#include <stdint.h>
#include <sys/types.h>

struct archive;
struct archive_entry;
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1

struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
#endif
