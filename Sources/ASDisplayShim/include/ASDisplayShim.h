#ifndef ASDISPLAYSHIM_H
#define ASDISPLAYSHIM_H

#include <CoreGraphics/CoreGraphics.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Availability probe: verifies the runtime provides the CGVirtualDisplay class
 * cluster AND that every required selector carries the exact method signature
 * this shim will call (return type + argument encodings - NSUInteger vs
 * unsigned, CGFloat, struct size). Allocates nothing. Returns 1 when usable;
 * otherwise 0 with a precise reason written into errbuf. */
int ASVDProbe(char *errbuf, size_t errcap);

/* Create a private virtual display. Returns a retained opaque handle (owns the
 * underlying object) or NULL with a precise failure in errbuf.
 *   width/height  point size of the display mode
 *   refresh       Hz, 0 selects the default 60
 *   hiDPI         1 asks for a Retina backing store, 0 standard
 *   vendor/product/serial  identity triple reported to the OS
 *   name          display label as a UTF-8 C string (NULL selects a default);
 *                 converted inside the shim via stringWithUTF8String
 *   millimeters   physical size hint (CGSize)
 *   terminated    optional block(void) invoked if the OS tears the display
 *                 down out from under the owner; may be NULL. The shim decides
 *                 the concrete block signature from the runtime's own
 *                 terminationHandler property ABI; it is never guessed. */
void *ASVDCreate(unsigned int width, unsigned int height, double refresh, int hiDPI,
                 unsigned int vendorID, unsigned int productID, unsigned int serial,
                 const char *name, CGSize millimeters, void (^terminated)(void),
                 char *errbuf, size_t errcap);

/* Read-only test hook: runs the same UTF-8 C-string -> NSString conversion
 * ASVDCreate applies to `name` and echoes the result into `out`. Lets
 * regression checks prove argument interpretation without a display. */
int ASVDProbeName(const char *utf8, char *out, size_t outcap);

/* CGDirectDisplayID of a live handle, 0 for NULL/dead. */
unsigned int ASVDDisplayID(void *handle);

/* Drop the handle's ownership; the OS removes the display. Idempotent-safe. */
void ASVDRelease(void *handle);

#ifdef __cplusplus
}
#endif
#endif
