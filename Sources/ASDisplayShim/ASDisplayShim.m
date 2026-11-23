/* AgentSpace-owned shim over the private CoreGraphics CGVirtualDisplay class
 * cluster. Every class and selector is discovered at runtime - no private
 * symbols are referenced at compile or link time - and every selector that
 * will be invoked has its method signature checked against the encoding the
 * call site was written for (return type plus per-argument encodings, so
 * `unsigned int` is never sent where `NSUInteger` lives and a struct arg is
 * never pushed into an object slot). An incompatible ABI is a clean,
 * described failure, never an ObjC exception and never a wrong-typed send.
 * Compiled under ARC; the display object is handed to C callers as a +1
 * opaque handle via CFBridgingRetain/Release. */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
#include "ASDisplayShim.h"

static void fail(char *errbuf, size_t cap, NSString *message) {
    if (errbuf && cap) {
        strlcpy(errbuf, message ? message.UTF8String : "unknown failure", cap);
    }
}

static Class vdClass(const char *name) { return objc_getClass(name); }
static SEL vdSEL(const char *name) { return NSSelectorFromString([NSString stringWithUTF8String:name]); }

/* One argument-encoding expectation. Scalars compare exactly ('I' vs 'Q'
 * matters: unsigned int is not NSUInteger); a '{...=...}' expectation also
 * requires the runtime encoding to be a struct of identical member layout and
 * total size, compared without any architecture-offset arithmetic. */
static BOOL argMatches(NSMethodSignature *sig, NSUInteger index, const char *expect) {
    const char *enc = [sig getArgumentTypeAtIndex:index];
    if (!enc) { return NO; }
    if (expect[0] == '{') {
        if (enc[0] != '{') { return NO; }
        NSUInteger eSize = 0, aSize = 0, eAlign = 0, aAlign = 0;
        NSGetSizeAndAlignment(expect, &eSize, &eAlign);
        NSGetSizeAndAlignment(enc, &aSize, &aAlign);
        const char *eTail = strchr(expect, '=');
        const char *aTail = strchr(enc, '=');
        if (eTail && aTail && strcmp(eTail, aTail) != 0) { return NO; }
        return eSize == aSize && eSize > 0;
    }
    return strcmp(enc, expect) == 0;
}

/* Return encodings must match exactly - with one exception: 'c' (char) and
 * 'B' (C_BOOL) are the same 1-byte ABI for BOOL returns; modern toolchains on
 * arm64 encode BOOL as 'B' while older/intel metadata says 'c'. */
static BOOL retMatches(const char *actual, const char *expect) {
    if (!actual) { return NO; }
    if (strcmp(actual, expect) == 0) { return YES; }
    return actual[0] && actual[1] == 0 && expect[0] && expect[1] == 0
        && ((actual[0] == 'c' && expect[0] == 'B') || (actual[0] == 'B' && expect[0] == 'c'));
}

/* Check that instances of `cls` respond to `selName` with exactly the
 * signature the call site needs. `required` controls whether a mismatch also
 * writes the failure reason (callers then abort) or is simply reported NO so
 * the optional step can be skipped. */
static BOOL checkSig(Class cls, const char *selName, const char *retType,
                     const char *const argTypes[], int argCount,
                     char *errbuf, size_t cap, BOOL required) {
    SEL sel = vdSEL(selName);
    NSString *what = [NSString stringWithFormat:@"%s %s", class_getName(cls), selName];
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
    if (!sig) {
        if (required) fail(errbuf, cap, [NSString stringWithFormat:@"%@ missing", what]);
        return NO;
    }
    const char *actualRet = sig.methodReturnType;
    if (!actualRet || !retMatches(actualRet, retType)) {
        if (required) fail(errbuf, cap,
            [NSString stringWithFormat:@"%@ returns '%s', expected '%s'", what, actualRet ?: "?", retType]);
        return NO;
    }
    if ((int)sig.numberOfArguments != argCount + 2) {
        if (required) fail(errbuf, cap,
            [NSString stringWithFormat:@"%@ takes %lu arguments, expected %d",
                what, (unsigned long)(sig.numberOfArguments - 2), argCount]);
        return NO;
    }
    for (int i = 0; i < argCount; i++) {
        if (!argMatches(sig, (NSUInteger)i + 2, argTypes[i])) {
            const char *actual = [sig getArgumentTypeAtIndex:(NSUInteger)i + 2];
            if (required) fail(errbuf, cap,
                [NSString stringWithFormat:@"%@ argument %d is '%s', expected '%s'",
                    what, i, actual ?: "?", argTypes[i]]);
            return NO;
        }
    }
    return YES;
}

/* Unsigned-integer property setter driven by the runtime's OWN argument
 * encoding - the value is passed as the exact width the selector declares. */
static BOOL setUInteger(id obj, const char *selName, unsigned long value,
                        char *errbuf, size_t cap) {
    Class cls = object_getClass(obj);
    SEL sel = vdSEL(selName);
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
    const char *enc = sig ? [sig getArgumentTypeAtIndex:2] : NULL;
    if (!enc) {
        fail(errbuf, cap, [NSString stringWithFormat:@"%s %s missing argument encoding", class_getName(cls), selName]);
        return NO;
    }
    switch (enc[0]) {
        case 'I': ((void (*)(id, SEL, unsigned int))objc_msgSend)(obj, sel, (unsigned int)value); return YES;
        case 'Q': ((void (*)(id, SEL, unsigned long))objc_msgSend)(obj, sel, value); return YES;
        case 'i': ((void (*)(id, SEL, int))objc_msgSend)(obj, sel, (int)value); return YES;
        case 'S': ((void (*)(id, SEL, unsigned short))objc_msgSend)(obj, sel, (unsigned short)value); return YES;
        case 'C': case 'B': ((void (*)(id, SEL, unsigned char))objc_msgSend)(obj, sel, (unsigned char)value); return YES;
        default:
            fail(errbuf, cap, [NSString stringWithFormat:@"%s %s wants '%s' — not an integer the shim sends",
                class_getName(cls), selName, enc]);
            return NO;
    }
}

/* Parameter count of the runtime's terminationHandler block property, parsed
 * from the property's own type attributes: 0 for void(^)(void), 1 for a block
 * taking the display object, -1 when the property or its signature is
 * unreadable. Never guessed. */
static int terminationArity(Class descriptorClass) {
    objc_property_t prop = class_getProperty(descriptorClass, "terminationHandler");
    if (!prop) { return -1; }
    const char *attrs = property_getAttributes(prop);
    if (!attrs) { return -1; }
    const char *encoded = strstr(attrs, "<");
    const char *end = encoded ? strstr(encoded, ">") : NULL;
    if (!encoded || !end) { return 0; } /* block type without embedded signature */
    const char *at = strstr(encoded, "@?");
    if (!at || at > end) { return -1; }
    int count = 0;
    for (const char *p = at + 2; p < end && *p; ) {
        if (*p == '{') {
            int depth = 1; p++;
            while (p < end && *p && depth) { if (*p == '{') depth++; if (*p == '}') depth--; p++; }
            count++;
            continue;
        }
        if (*p == '[') {
            int depth = 1; p++;
            while (p < end && *p && depth) { if (*p == '[') depth++; if (*p == ']') depth--; p++; }
            count++;
            continue;
        }
        if (strchr("cislqCISLQBfdv*@#?:", *p)) { if (*p != 'v' && *p != ':') count++; p++; continue; }
        if (*p >= '0' && *p <= '9') { p++; continue; }
        p++;
    }
    return count;
}

int ASVDProbe(char *errbuf, size_t cap) {
    if (!vdClass("CGVirtualDisplay")) {
        fail(errbuf, cap, @"CGVirtualDisplay class absent on this OS");
        return 0;
    }
    if (!vdClass("CGVirtualDisplayDescriptor")) {
        fail(errbuf, cap, @"CGVirtualDisplayDescriptor class absent");
        return 0;
    }
    if (!vdClass("CGVirtualDisplaySettings")) {
        fail(errbuf, cap, @"CGVirtualDisplaySettings class absent");
        return 0;
    }
    if (!vdClass("CGVirtualDisplayMode")) {
        fail(errbuf, cap, @"CGVirtualDisplayMode class absent");
        return 0;
    }
    /* The selectors the create path cannot degrade around must exist AND match
     * the exact signatures it will call - an ABI drift here would otherwise
     * push the wrong argument shape onto the stack. */
    const char *idArg[] = {"@"};
    const char *modeArgs[] = {"I", "I", "d"};
    const char *uintArg[] = {"I"};
    if (!checkSig(vdClass("CGVirtualDisplay"), "initWithDescriptor:", "@", idArg, 1, errbuf, cap, YES)) return 0;
    if (!checkSig(vdClass("CGVirtualDisplay"), "applySettings:", "c", idArg, 1, errbuf, cap, YES)) return 0;
    if (!checkSig(vdClass("CGVirtualDisplay"), "displayID", "I", NULL, 0, errbuf, cap, YES)) return 0;
    if (!checkSig(vdClass("CGVirtualDisplayMode"), "initWithWidth:height:refreshRate:", "@", modeArgs, 3, errbuf, cap, YES)) return 0;
    if (!checkSig(vdClass("CGVirtualDisplaySettings"), "setHiDPI:", "v", uintArg, 1, errbuf, cap, YES)) return 0;
    if (!checkSig(vdClass("CGVirtualDisplaySettings"), "setModes:", "v", idArg, 1, errbuf, cap, YES)) return 0;
    fail(errbuf, cap, @"CGVirtualDisplay classes present with required signatures");
    return 1;
}

void *ASVDCreate(unsigned int width, unsigned int height, double refresh, int hiDPI,
                 unsigned int vendorID, unsigned int productID, unsigned int serial,
                 const char *name, CGSize millimeters, void (^terminated)(void),
                 char *errbuf, size_t cap) {
    @autoreleasepool {
        Class descriptorClass = vdClass("CGVirtualDisplayDescriptor");
        Class settingsClass = vdClass("CGVirtualDisplaySettings");
        Class displayClass = vdClass("CGVirtualDisplay");
        Class modeClass = vdClass("CGVirtualDisplayMode");
        if (!descriptorClass || !settingsClass || !displayClass || !modeClass) {
            fail(errbuf, cap, @"CGVirtualDisplay classes unavailable on this macOS");
            return NULL;
        }
        const char *idArg[] = {"@"};
        const char *pointArg[] = {"{CGPoint=dd}"};
        const char *sizeArg[] = {"{CGSize=dd}"};
        const char *modeArgs[] = {"I", "I", "d"};
        const char *uintArg[] = {"I"};
        id descriptor = ((id(*)(id, SEL))objc_msgSend)([descriptorClass alloc], @selector(init));
        if (!descriptor) {
            fail(errbuf, cap, @"CGVirtualDisplayDescriptor init failed");
            return NULL;
        }
        /* Chromaticity coordinates for a standard sRGB display (D65 white
         * point + sRGB primaries). Optional setters: each is invoked only when
         * the runtime signature is a CGPoint parameter - never as an object. */
        NSDictionary *chromaticity = @{
            @"setWhitePoint:": [NSValue valueWithPoint:NSMakePoint(0.3127, 0.3290)],
            @"setRedPrimary:": [NSValue valueWithPoint:NSMakePoint(0.6400, 0.3300)],
            @"setGreenPrimary:": [NSValue valueWithPoint:NSMakePoint(0.3000, 0.6000)],
            @"setBluePrimary:": [NSValue valueWithPoint:NSMakePoint(0.1500, 0.0600)],
        };
        for (NSString *selName in chromaticity) {
            const char *cName = selName.UTF8String;
            if (checkSig(descriptorClass, cName, "v", pointArg, 1, errbuf, cap, NO)) {
                CGPoint point = [chromaticity[selName] pointValue];
                ((void(*)(id, SEL, CGPoint))objc_msgSend)(descriptor, vdSEL(cName), point);
            }
        }
        /* Termination plumbing is installed on the DESCRIPTOR before
         * initWithDescriptor: - the queue that delivers the callback, then the
         * block whose arity the runtime's own property attributes declared. */
        if (terminated) {
            static dispatch_queue_t terminationQueue = NULL;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                terminationQueue = dispatch_queue_create("agentspace.display.termination", DISPATCH_QUEUE_SERIAL);
            });
            if (checkSig(descriptorClass, "setQueue:", "v", idArg, 1, errbuf, cap, NO)) {
                ((void(*)(id, SEL, id))objc_msgSend)(descriptor, vdSEL("setQueue:"), terminationQueue);
            }
            /* The setter's argument is a BLOCK: the runtime encodes it '@?'
             * (older metadata may say '@' - a block literal satisfies both).
             * Checking only '@' silently skipped installation on every modern
             * runtime; the '@?' expectation is tried first so the callback is
             * actually installed where the ABI allows it. */
            const char *blockArg[] = {"@?"};
            if (checkSig(descriptorClass, "setTerminationHandler:", "v", blockArg, 1, errbuf, cap, NO)
                || checkSig(descriptorClass, "setTerminationHandler:", "v", idArg, 1, errbuf, cap, NO)) {
                int arity = terminationArity(descriptorClass);
                if (arity == 1) {
                    void (^handler)(id) = ^(id _display) { terminated(); };
                    ((void(*)(id, SEL, id))objc_msgSend)(descriptor, vdSEL("setTerminationHandler:"), handler);
                } else if (arity == 0) {
                    void (^handler)(void) = ^{ terminated(); };
                    ((void(*)(id, SEL, id))objc_msgSend)(descriptor, vdSEL("setTerminationHandler:"), handler);
                }
                /* Unreadable or unexpected block ABI: the handler is skipped,
                 * never guessed - host-side liveness checks still apply. */
            }
        }
        NSString *label = name ? [NSString stringWithUTF8String:name] : nil;
        if (checkSig(descriptorClass, "setName:", "v", idArg, 1, errbuf, cap, NO)) {
            ((void(*)(id, SEL, id))objc_msgSend)(descriptor, vdSEL("setName:"), label ?: @"AgentSpace");
        }
        if (checkSig(descriptorClass, "setSizeInMillimeters:", "v", sizeArg, 1, errbuf, cap, NO)) {
            ((void(*)(id, SEL, CGSize))objc_msgSend)(descriptor, vdSEL("setSizeInMillimeters:"), millimeters);
        }
        /* Optional integer setters - each sent at the width the runtime
         * signature declares (unsigned int vs NSUInteger). A declaration the
         * shim cannot satisfy skips the call, it never forces one. */
        setUInteger(descriptor, "setMaxPixelsWide:", (unsigned long)width * (hiDPI ? 2 : 1), NULL, 0);
        setUInteger(descriptor, "setMaxPixelsHigh:", (unsigned long)height * (hiDPI ? 2 : 1), NULL, 0);
        setUInteger(descriptor, "setProductID:", productID, NULL, 0);
        setUInteger(descriptor, "setVendorID:", vendorID, NULL, 0);
        setUInteger(descriptor, "setSerialNum:", serial, NULL, 0);
        id display = ((id(*)(id, SEL, id))objc_msgSend)(
            [displayClass alloc], vdSEL("initWithDescriptor:"), descriptor);
        if (!display) {
            fail(errbuf, cap, @"CGVirtualDisplay initWithDescriptor: returned nil");
            return NULL;
        }
        id settings = ((id(*)(id, SEL))objc_msgSend)([settingsClass alloc], @selector(init));
        if (!settings) {
            fail(errbuf, cap, @"CGVirtualDisplaySettings init failed");
            return NULL;
        }
        /* setHiDPI: is a required 'I' (unsigned int) argument - the probe
         * already verified the ABI, so a mismatch here is a hard failure, not
         * a silent wrong-typed send. */
        if (!checkSig(settingsClass, "setHiDPI:", "v", uintArg, 1, errbuf, cap, YES)) {
            return NULL;
        }
        ((void(*)(id, SEL, unsigned int))objc_msgSend)(settings, vdSEL("setHiDPI:"), hiDPI ? 1u : 0u);
        if (!checkSig(modeClass, "initWithWidth:height:refreshRate:", "@", modeArgs, 3, errbuf, cap, YES)) {
            return NULL;
        }
        id mode = ((id(*)(id, SEL, unsigned int, unsigned int, double))objc_msgSend)(
            [modeClass alloc], vdSEL("initWithWidth:height:refreshRate:"),
            width, height, refresh > 0 ? refresh : 60.0);
        if (!mode) {
            fail(errbuf, cap, @"CGVirtualDisplayMode initWithWidth:height:refreshRate: failed");
            return NULL;
        }
        if (!checkSig(settingsClass, "setModes:", "v", idArg, 1, errbuf, cap, YES)) {
            return NULL;
        }
        ((void(*)(id, SEL, id))objc_msgSend)(settings, vdSEL("setModes:"),
                                             [NSArray arrayWithObject:mode]);
        BOOL applied = ((BOOL(*)(id, SEL, id))objc_msgSend)(display, vdSEL("applySettings:"),
                                                            settings);
        if (!applied) {
            fail(errbuf, cap, @"CGVirtualDisplay applySettings: failed");
            return NULL;
        }
        return (void *)CFBridgingRetain(display);
    }
}

int ASVDProbeName(const char *utf8, char *out, size_t outcap) {
    if (!out || !outcap) { return 0; }
    if (!utf8) {
        strlcpy(out, "", outcap);
        return 1;
    }
    NSString *label = [NSString stringWithUTF8String:utf8];
    if (!label) {
        strlcpy(out, "", outcap);
        return 0;
    }
    strlcpy(out, label.UTF8String, outcap);
    return 1;
}

unsigned int ASVDDisplayID(void *handle) {
    if (!handle) { return 0; }
    id display = (__bridge id)handle;
    Class cls = object_getClass(display);
    SEL sel = @selector(displayID);
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
    const char *enc = sig ? sig.methodReturnType : NULL;
    if (!enc) { return 0; }
    switch (enc[0]) {
        case 'I': return ((unsigned int(*)(id, SEL))objc_msgSend)(display, sel);
        case 'Q': return (unsigned int)((unsigned long(*)(id, SEL))objc_msgSend)(display, sel);
        case 'S': return ((unsigned short(*)(id, SEL))objc_msgSend)(display, sel);
        default: return 0;
    }
}

void ASVDRelease(void *handle) {
    if (handle) { CFBridgingRelease(handle); }
}
