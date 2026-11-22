module desktop_probe;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.time : MonoTime;

@safe:

/// SDL render dimensions used for both profile measurements.
enum width = 512;
/// SDL render dimensions used for both profile measurements.
enum height = 320;
/// Matching native window title.
enum title = "Flint benchmark";

/// Verification that remains active in release builds.
void require(bool success) pure nothrow @nogc
{
    if (!success)
        assert(0, "desktop benchmark invariant failed");
}

/// Select the fixed replay length for a correctness or timed run.
size_t count(string[] args)
{
    require(args.length == 1 || (args.length == 2 && args[1] == "--measure"));
    return args.length == 2 ? 8192 : 1;
}

/// Record startup, steady rendering and the native output sample.
void report(size_t frames, MonoTime start, MonoTime ready, MonoTime rendered, ulong prior, ulong checksum)
{
    const measured = GC.stats().allocatedInCurrentThread - prior;
    require(measured == 0 && checksum != 0);
    printFrames(frames, checksum);
    if (frames > 1)
        printTiming((ready - start).total!"usecs", (rendered - ready).total!"usecs", measured);
}

// SAFETY: Fixed NUL-terminated literal format with matching scalar arguments.
private void printFrames(size_t frames, ulong checksum) @trusted nothrow @nogc
{
    printf("desktop frames=%zu width=%d height=%d checksum=%llu\n", frames, width, height, checksum);
}

// SAFETY: Fixed NUL-terminated literal format with matching scalar arguments.
private void printTiming(long startup, long render, ulong measured) @trusted nothrow @nogc
{
    printf("desktop startup_us=%lld render_us=%lld gc_bytes=%llu\n", startup, render, measured);
}

private struct Surface;
private struct Renderer;
private struct SdlWindow;

extern (C) private @system nothrow @nogc
{
    pragma(mangle, "SDL_SetHint") bool setHint(const(char)*, const(char)*);
    pragma(mangle, "SDL_GetWindows") SdlWindow** getWindows(int*);
    pragma(mangle, "SDL_GetRenderer") Renderer* getRenderer(SdlWindow*);
    pragma(mangle, "SDL_RenderReadPixels") Surface* readPixels(Renderer*, const(void)*);
    pragma(mangle, "SDL_ReadSurfacePixel") bool readPixel(Surface*, int, int, ubyte*, ubyte*, ubyte*, ubyte*);
    pragma(mangle, "SDL_DestroySurface") void releaseSurface(Surface*);
    pragma(mangle, "SDL_free") void sdlFree(void*);
}

/// Commit to SDL's native software renderer and dummy display for comparable readback.
// SAFETY: These are static C strings and this setup runs on the benchmark's main thread.
void chooseDriver() @trusted nothrow @nogc
{
    require(setHint("SDL_VIDEO_DRIVER", "dummy"));
    require(setHint("SDL_RENDER_DRIVER", "software"));
}

/// Verify native colors drawn by the renderer and consume them in a deterministic checksum.
// SAFETY: The owner benchmark still has exactly one live SDL window. Readback returns an
// owned surface and SDL only writes the four provided single-byte outputs.
ulong verifyNativeFrame() @trusted nothrow @nogc
{
    int count;
    auto windows = getWindows(&count);
    require(windows !is null && count == 1);
    auto renderer = getRenderer(windows[0]);
    sdlFree(windows);
    require(renderer !is null);
    auto output = readPixels(renderer, null);
    require(output !is null);
    scope (exit)
        releaseSurface(output);
    ulong checksum;
    foreach (sample; [
        ColorSample(1, 1, 16, 24, 36), ColorSample(9, 11, 56, 140, 92),
        ColorSample(80, 20, 80, 112, 184)
    ])
    {
        ubyte red, green, blue, alpha;
        require(readPixel(output, sample.x, sample.y, &red, &green, &blue, &alpha));
        require(red == sample.red && green == sample.green && blue == sample.blue && alpha == 255);
        checksum = checksum * 1_000_003 + cast(ulong) red * 65_536 + cast(ulong) green * 256 + blue;
    }
    return checksum;
}

private struct ColorSample
{
    int x, y;
    ubyte red, green, blue;
}
