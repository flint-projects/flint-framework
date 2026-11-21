module app;

import core.memory : GC;
import core.time : MonoTime;
import desktop_probe : chooseDriver, count, height, report, require, title, verifyNativeFrame, width;

@safe:

private struct SdlWindow;
private struct Renderer;
private struct Texture;

private struct Rect
{
    int x, y, w, h;
}

private struct FRect
{
    float x, y, w, h;
}

private union Event
{
    ulong alignment;
    ubyte[128] bytes;
}

extern (C) private @system nothrow @nogc
{
    pragma(mangle, "SDL_InitSubSystem") bool initSubSystem(uint);
    pragma(mangle, "SDL_QuitSubSystem") void quitSubSystem(uint);
    pragma(mangle, "SDL_CreateWindowAndRenderer") bool createWindowAndRenderer(const(char)*, int,
            int, ulong, SdlWindow**, Renderer**);
    pragma(mangle, "SDL_CreateTexture") Texture* createTexture(Renderer*, uint, uint, int, int);
    pragma(mangle, "SDL_UpdateTexture") bool updateTexture(Texture*, const(Rect)*, const(void)*, int);
    pragma(mangle, "SDL_SetTextureBlendMode") bool setTextureBlendMode(Texture*, uint);
    pragma(mangle, "SDL_SetRenderDrawBlendMode") bool setDrawBlendMode(Renderer*, uint);
    pragma(mangle, "SDL_DestroyTexture") void destroyTexture(Texture*);
    pragma(mangle, "SDL_DestroyRenderer") void destroyRenderer(Renderer*);
    pragma(mangle, "SDL_DestroyWindow") void destroyWindow(SdlWindow*);
    pragma(mangle, "SDL_SetRenderDrawColor") bool setColor(Renderer*, ubyte, ubyte, ubyte, ubyte);
    pragma(mangle, "SDL_RenderClear") bool clear(Renderer*);
    pragma(mangle, "SDL_SetRenderClipRect") bool clip(Renderer*, const(Rect)*);
    pragma(mangle, "SDL_RenderFillRect") bool fill(Renderer*, const(FRect)*);
    pragma(mangle, "SDL_RenderDebugText") bool glyphs(Renderer*, float, float, const(char)*);
    pragma(mangle, "SDL_SetTextureColorMod") bool textureColor(Texture*, ubyte, ubyte, ubyte);
    pragma(mangle, "SDL_SetTextureAlphaMod") bool textureAlpha(Texture*, ubyte);
    pragma(mangle, "SDL_RenderTexture") bool image(Renderer*, Texture*, const(FRect)*, const(FRect)*);
    pragma(mangle, "SDL_RenderPresent") bool present(Renderer*);
    pragma(mangle, "SDL_PollEvent") bool poll(Event*);
}

private struct Session
{
    SdlWindow* window;
    Renderer* renderer;
    Texture* tile;
}

private enum subsystems = 0x4020;

// SAFETY: This main-thread fixture owns all three provider handles. The pixel value is scoped.
private Session open() @trusted nothrow @nogc
{
    Session session;
    require(initSubSystem(subsystems));
    require(createWindowAndRenderer(title.ptr, width, height, 0x20, &session.window, &session.renderer));
    session.tile = createTexture(session.renderer, 0x16762004, 0, 1, 1);
    require(session.tile !is null);
    const ubyte[4] white = [255, 255, 255, 255];
    require(updateTexture(session.tile, null, &white[0], 4));
    require(setTextureBlendMode(session.tile, 1) && setDrawBlendMode(session.renderer, 1));
    return session;
}

// SAFETY: The main-thread fixture still owns the renderer and tile. SDL borrows literal geometry and color.
private void frame(ref Session session) @trusted nothrow @nogc
{
    auto renderer = session.renderer;
    Event next;
    while (poll(&next))
    {
    }
    require(clip(renderer, null) && setColor(renderer, 16, 24, 36, 255) && clear(renderer));
    const clipRect = Rect(4, 5, 500, 305);
    require(clip(renderer, &clipRect));
    const rect = FRect(8, 10, 40, 20);
    require(setColor(renderer, 56, 140, 92, 255) && fill(renderer, &rect));
    require(setColor(renderer, 200, 208, 216, 255) && glyphs(renderer, 12, 24, "FLNT"));
    require(textureColor(session.tile, 80, 112, 184) && textureAlpha(session.tile, 255));
    const tile = FRect(70, 10, 30, 21);
    require(image(renderer, session.tile, null, &tile));
    require(clip(renderer, null) && present(renderer));
}

// SAFETY: This destroys the fixture-owned texture, renderer and window in their native ownership order.
private void close(ref Session session) @trusted nothrow @nogc
{
    destroyTexture(session.tile);
    destroyRenderer(session.renderer);
    destroyWindow(session.window);
    quitSubSystem(subsystems);
}

void main(string[] arguments)
{
    const frames = count(arguments);
    chooseDriver();
    const start = MonoTime.currTime;
    auto session = open();
    const ready = MonoTime.currTime;
    const allocated = GC.stats().allocatedInCurrentThread;
    foreach (_; 0 .. frames)
        frame(session);
    const rendered = MonoTime.currTime;
    const checksum = verifyNativeFrame();
    close(session);
    report(frames, start, ready, rendered, allocated, checksum);
}
