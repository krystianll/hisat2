/*
 * gzip_reader.cpp
 *
 * Implementation of the thin zlib wrapper declared in gzip_reader.h. This is
 * the ONLY translation unit that includes <zlib.h>; everything else deals in
 * opaque handles. See gzip_reader.h for the rationale.
 */

#include "gzip_reader.h"

#include <stdio.h>
#include <stdlib.h>
#include <zlib.h>

/* dup(): POSIX <unistd.h>, or _dup() from <io.h> on Windows. */
#ifdef _WIN32
#include <io.h>
#define gzr_dup _dup
#define gzr_closefd _close
#else
#include <unistd.h>
#define gzr_dup dup
#define gzr_closefd close
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Report a decompression error to stderr and abort. gzread's own error
 * messages omit errno detail for Z_ERRNO, so fall back to a generic message. */
static void fatal_gz_error(gzFile gz) {
	int errnum = 0;
	const char* msg = gzerror(gz, &errnum);
	fprintf(stderr,
		"Error: failed to read/decompress input (%s)\n",
		(msg != NULL && *msg) ? msg : "unknown zlib error");
	exit(1);
}

void* gzr_open(const char* path) {
	gzFile gz = gzopen(path, "rb");
	if(gz != NULL) {
		/* Match FileBuf's 256 KiB chunking for throughput; harmless if it fails. */
		gzbuffer(gz, 256 * 1024);
	}
	return (void*)gz;
}

void* gzr_dopen(int fd) {
	/* dup so gzclose() does not close the caller's fd (e.g. real stdin). */
	int fd2 = gzr_dup(fd);
	if(fd2 < 0) {
		return NULL;
	}
	gzFile gz = gzdopen(fd2, "rb");
	if(gz == NULL) {
		gzr_closefd(fd2); /* gzdopen did not take ownership on failure */
		return NULL;
	}
	gzbuffer(gz, 256 * 1024);
	return (void*)gz;
}

size_t gzr_read(void* h, char* buf, size_t n) {
	if(h == NULL) return 0;
	gzFile gz = (gzFile)h;
	/* Fill the whole buffer, looping until it is full or gzread signals a
	 * definitive end-of-stream (a 0 return). We cannot stop at the first
	 * short read: zlib only discovers a truncated stream on the *next*
	 * gzread (the one that returns 0 with a negative errnum), but the caller
	 * (FileBuf) treats any short read as EOF and never calls back -- so a
	 * single short read carrying the whole truncated payload would slip
	 * through as a clean, exit-0 run with too few reads. Forcing the
	 * terminating read here surfaces the error. All zlib error codes are
	 * negative; Z_OK(0)/Z_STREAM_END(1) are not errors. */
	size_t got = 0;
	while(got < n) {
		int ret = gzread(gz, buf + got, (unsigned)(n - got));
		if(ret < 0) {
			fatal_gz_error(gz);
		}
		/* Check the error state after EVERY read, before acting on a 0 return.
		 * A truncated stream is reported at different moments across zlib
		 * builds: macOS/Linux flag it on the follow-up ret==0 read, while the
		 * Windows (MSYS2) build flags it on the SAME partial ret>0 read and
		 * then CLEARS it before the ret==0 read. Checking here catches both;
		 * a clean read never leaves a negative errnum. */
		int errnum = 0;
		gzerror(gz, &errnum);
		if(errnum < 0) {
			fatal_gz_error(gz);
		}
		if(ret == 0) {
			break; /* clean end of stream */
		}
		got += (size_t)ret;
	}
	return got;
}

void gzr_rewind(void* h) {
	if(h == NULL) return;
	gzrewind((gzFile)h);
}

void gzr_close(void* h) {
	if(h == NULL) return;
	gzclose((gzFile)h);
}

#ifdef __cplusplus
} /* extern "C" */
#endif
