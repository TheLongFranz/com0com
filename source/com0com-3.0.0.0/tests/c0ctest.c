/*
 * c0ctest.c - native Win32 smoke/conformance tests for a com0com port pair.
 *
 *   c0ctest <portA> <portB> [emubr|noemubr]
 *   e.g.    c0ctest COM31 COM32      or      c0ctest CNCA0 CNCB0 noemubr
 *
 * The two ports must be the two ends of one pair. The optional third argument adds a baud-rate
 * emulation timing test: "emubr" if the pair was created with EmuBR=yes, "noemubr" if it was not.
 * Exit code 0 = every check passed.
 * Uses only documented Win32 comm APIs, so the same source is built as native ARM64, x64 (emulated)
 * and x86 (WOW64) to exercise every IOCTL calling path of the driver.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static int g_pass, g_fail;
static HANDLE hA, hB;
static const char *nameA, *nameB;

static void report(const char *name, BOOL ok, const char *fmt, ...)
{
    char detail[256] = "";
    if (fmt) { va_list ap; va_start(ap, fmt); _vsnprintf(detail, sizeof(detail) - 1, fmt, ap); va_end(ap); }
    if (ok) g_pass++; else g_fail++;
    printf("  [%s] %-46s %s\n", ok ? "PASS" : "FAIL", name, detail);
    fflush(stdout);
}

static void section(const char *s) { printf("\n%s\n", s); fflush(stdout); }

/* ---------------------------------------------------------------- helpers */

static HANDLE openPort(const char *name)
{
    char path[128];
    _snprintf(path, sizeof(path) - 1, "\\\\.\\%s", name);
    path[sizeof(path) - 1] = 0;
    return CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
}

static void setTimeouts(HANDLE h, DWORD interval, DWORD mult, DWORD constant)
{
    COMMTIMEOUTS t;
    t.ReadIntervalTimeout = interval;
    t.ReadTotalTimeoutMultiplier = mult;
    t.ReadTotalTimeoutConstant = constant;
    t.WriteTotalTimeoutMultiplier = 0;
    t.WriteTotalTimeoutConstant = 0;
    SetCommTimeouts(h, &t);
}

/* Read completes as soon as at least one byte is available, or after ms with 0 bytes. */
static void readAny(HANDLE h, DWORD ms) { setTimeouts(h, MAXDWORD, MAXDWORD, ms); }

static void setLine(HANDLE h, DWORD baud, BYTE bits, BYTE parity, BYTE stop)
{
    DCB d;
    memset(&d, 0, sizeof(d)); d.DCBlength = sizeof(d);
    GetCommState(h, &d);
    d.BaudRate = baud; d.ByteSize = bits; d.Parity = parity; d.StopBits = stop;
    d.fBinary = TRUE; d.fParity = FALSE;
    d.fOutxCtsFlow = FALSE; d.fOutxDsrFlow = FALSE; d.fOutX = FALSE; d.fInX = FALSE;
    d.fDtrControl = DTR_CONTROL_ENABLE; d.fRtsControl = RTS_CONTROL_ENABLE;
    d.fNull = FALSE; d.fAbortOnError = FALSE; d.fErrorChar = FALSE;
    d.XonChar = 0x11; d.XoffChar = 0x13;
    SetCommState(h, &d);
}

static void resetPort(HANDLE h)
{
    SetCommMask(h, 0);
    setLine(h, 115200, 8, NOPARITY, ONESTOPBIT);
    readAny(h, 2000);
    PurgeComm(h, PURGE_RXCLEAR | PURGE_TXCLEAR | PURGE_RXABORT | PURGE_TXABORT);
    EscapeCommFunction(h, SETRTS);
    EscapeCommFunction(h, SETDTR);
    EscapeCommFunction(h, CLRBREAK);
}

static void resetBoth(void) { resetPort(hA); resetPort(hB); Sleep(30); }

/* Returns bytes read (>=0); *err = 0, WAIT_TIMEOUT (nothing arrived in waitMs) or a Win32 error. */
static DWORD readSome(HANDLE h, void *buf, DWORD n, DWORD waitMs, DWORD *err)
{
    OVERLAPPED ov;
    DWORD got = 0;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    *err = 0;
    if (!ReadFile(h, buf, n, &got, &ov)) {
        DWORD e = GetLastError();
        if (e != ERROR_IO_PENDING) { *err = e; CloseHandle(ov.hEvent); return 0; }
        if (WaitForSingleObject(ov.hEvent, waitMs) == WAIT_TIMEOUT) {
            CancelIoEx(h, &ov);
            got = 0;
            GetOverlappedResult(h, &ov, &got, TRUE);
            *err = WAIT_TIMEOUT;
            CloseHandle(ov.hEvent);
            return got;
        }
        if (!GetOverlappedResult(h, &ov, &got, FALSE)) *err = GetLastError();
    }
    CloseHandle(ov.hEvent);
    return got;
}

static DWORD readExact(HANDLE h, void *buf, DWORD n, DWORD waitMs)
{
    DWORD total = 0, err;
    while (total < n) {
        DWORD g = readSome(h, (BYTE *)buf + total, n - total, waitMs, &err);
        total += g;
        if (g == 0) break;
    }
    return total;
}

static DWORD writeAll(HANDLE h, const void *buf, DWORD n, DWORD waitMs)
{
    OVERLAPPED ov;
    DWORD done = 0;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!WriteFile(h, buf, n, &done, &ov)) {
        if (GetLastError() != ERROR_IO_PENDING) { done = 0; goto out; }
        if (WaitForSingleObject(ov.hEvent, waitMs) == WAIT_TIMEOUT) {
            CancelIoEx(h, &ov);
            done = 0;
            GetOverlappedResult(h, &ov, &done, TRUE);
            goto out;
        }
        GetOverlappedResult(h, &ov, &done, FALSE);
    }
out:
    CloseHandle(ov.hEvent);
    return done;
}

/* An overlapped write that is left pending on purpose (flow-control tests). */
typedef struct { OVERLAPPED ov; BYTE data[256]; DWORD len; DWORD done; } PENDINGIO;

static void startWrite(HANDLE h, PENDINGIO *p, DWORD n)
{
    DWORD i;
    memset(p, 0, sizeof(*p));
    p->ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    p->len = n;
    for (i = 0; i < n; i++) p->data[i] = (BYTE)(i + 1);
    if (!WriteFile(h, p->data, n, &p->done, &p->ov) && GetLastError() != ERROR_IO_PENDING) p->done = (DWORD)-1;
}

static BOOL finishWrite(HANDLE h, PENDINGIO *p, DWORD waitMs)
{
    BOOL ok = FALSE;
    DWORD n = 0;
    if (WaitForSingleObject(p->ov.hEvent, waitMs) == WAIT_OBJECT_0) ok = GetOverlappedResult(h, &p->ov, &n, FALSE) && n == p->len;
    else { CancelIoEx(h, &p->ov); GetOverlappedResult(h, &p->ov, &n, TRUE); }
    CloseHandle(p->ov.hEvent);
    return ok;
}

/* WaitCommEvent helper: start, trigger something, then finish. */
typedef struct { HANDLE h; OVERLAPPED ov; DWORD mask; BOOL immediate; } EVWAIT;

static void evStart(EVWAIT *w, HANDLE h)
{
    memset(w, 0, sizeof(*w));
    w->h = h;
    w->ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (WaitCommEvent(h, &w->mask, &w->ov)) w->immediate = TRUE;
    else if (GetLastError() != ERROR_IO_PENDING) { w->mask = 0; w->immediate = TRUE; }   /* failed: report "no event" */
}

/* Returns the event mask, or 0 if nothing happened within waitMs. */
static DWORD evFinish(EVWAIT *w, DWORD waitMs)
{
    DWORD mask = 0, n;
    if (w->immediate) mask = w->mask;
    else if (WaitForSingleObject(w->ov.hEvent, waitMs) == WAIT_OBJECT_0) {
        if (GetOverlappedResult(w->h, &w->ov, &n, FALSE)) mask = w->mask;
    }
    else { CancelIoEx(w->h, &w->ov); GetOverlappedResult(w->h, &w->ov, &n, TRUE); }
    CloseHandle(w->ov.hEvent);
    return mask;
}

static DWORD modem(HANDLE h) { DWORD s = 0; GetCommModemStatus(h, &s); return s; }

/* ------------------------------------------------------------------ tests */

static void testOpen(void)
{
    section("open / exclusive access");
    hA = openPort(nameA);
    hB = openPort(nameB);
    report("open both ends", hA != INVALID_HANDLE_VALUE && hB != INVALID_HANDLE_VALUE,
           "A=%s B=%s (err %lu)", hA != INVALID_HANDLE_VALUE ? "ok" : "FAIL", hB != INVALID_HANDLE_VALUE ? "ok" : "FAIL", GetLastError());
    if (hA == INVALID_HANDLE_VALUE || hB == INVALID_HANDLE_VALUE) { printf("cannot continue\n"); exit(2); }

    {
        HANDLE again = openPort(nameA);
        DWORD e = GetLastError();
        report("second open of same port is refused", again == INVALID_HANDLE_VALUE && (e == ERROR_ACCESS_DENIED || e == ERROR_SHARING_VIOLATION), "error %lu", e);
        if (again != INVALID_HANDLE_VALUE) CloseHandle(again);
    }
}

static void testState(void)
{
    static const struct { DWORD baud; BYTE bits, parity, stop; } cfg[] = {
        { 300, 8, NOPARITY, ONESTOPBIT }, { 9600, 7, EVENPARITY, TWOSTOPBITS }, { 19200, 5, ODDPARITY, ONESTOPBIT },
        { 57600, 6, MARKPARITY, ONE5STOPBITS }, { 115200, 8, SPACEPARITY, ONESTOPBIT }, { 921600, 8, NOPARITY, ONESTOPBIT },
        { 12345, 8, NOPARITY, ONESTOPBIT }
    };
    int i, bad = 0;
    COMMTIMEOUTS t = { 11, 22, 33, 44, 55 }, r;
    COMMPROP prop;
    section("DCB / timeouts / properties");
    for (i = 0; i < (int)(sizeof(cfg) / sizeof(cfg[0])); i++) {
        HANDLE h[2]; int k;
        h[0] = hA; h[1] = hB;
        for (k = 0; k < 2; k++) {
            DCB d;
            memset(&d, 0, sizeof(d)); d.DCBlength = sizeof(d);
            GetCommState(h[k], &d);
            d.BaudRate = cfg[i].baud; d.ByteSize = cfg[i].bits; d.Parity = cfg[i].parity; d.StopBits = cfg[i].stop;
            if (!SetCommState(h[k], &d)) { bad++; continue; }
            memset(&d, 0, sizeof(d)); d.DCBlength = sizeof(d);
            if (!GetCommState(h[k], &d) || d.BaudRate != cfg[i].baud || d.ByteSize != cfg[i].bits || d.Parity != cfg[i].parity || d.StopBits != cfg[i].stop) bad++;
        }
    }
    report("SetCommState/GetCommState round-trip (7 cfgs x 2)", bad == 0, "%d mismatches", bad);
    resetBoth();

    memset(&r, 0, sizeof(r));
    report("SetCommTimeouts/GetCommTimeouts round-trip",
           SetCommTimeouts(hA, &t) && GetCommTimeouts(hA, &r) && !memcmp(&t, &r, sizeof(t)), NULL);
    readAny(hA, 2000);

    report("SetupComm(4096,4096)", SetupComm(hA, 4096, 4096), "err %lu", GetLastError());
    memset(&prop, 0, sizeof(prop));
    report("GetCommProperties", GetCommProperties(hA, &prop) && prop.wPacketLength != 0, "maxBaud=0x%lX", prop.dwMaxBaud);
}

static void testBasicData(void)
{
    BYTE all[256], rx[256];
    DWORD i, n, err;
    char buf[64];
    static const char m1[] = "Hello from A on ARM64", m2[] = "Reply from B";
    section("basic data transfer");
    resetBoth();

    n = writeAll(hA, m1, sizeof(m1), 2000);
    memset(buf, 0, sizeof(buf));
    n = readExact(hB, buf, sizeof(m1), 2000);
    report("A -> B text", n == sizeof(m1) && !memcmp(buf, m1, sizeof(m1)), "%lu bytes", n);

    writeAll(hB, m2, sizeof(m2), 2000);
    memset(buf, 0, sizeof(buf));
    n = readExact(hA, buf, sizeof(m2), 2000);
    report("B -> A text", n == sizeof(m2) && !memcmp(buf, m2, sizeof(m2)), "%lu bytes", n);

    for (i = 0; i < 256; i++) all[i] = (BYTE)i;
    writeAll(hA, all, 256, 2000);
    memset(rx, 0, sizeof(rx));
    n = readExact(hB, rx, 256, 2000);
    report("all 256 byte values, no translation", n == 256 && !memcmp(all, rx, 256), "%lu bytes", n);

    n = readSome(hB, rx, 16, 250, &err);
    report("no data -> read times out cleanly", n == 0 && err == WAIT_TIMEOUT, "got %lu, err %lu", n, err);

    n = writeAll(hA, "", 0, 500);
    report("zero-length write succeeds", n == 0, NULL);
}

/* ---- bulk streaming, both directions at once ---- */
typedef struct { HANDLE h; DWORD64 total; DWORD64 done; volatile LONG bad; DWORD seed; } STREAM;

static BYTE patternByte(DWORD64 pos) { return (BYTE)(pos * 131 + (pos >> 8) * 7 + 5); }

static DWORD WINAPI writerThread(LPVOID p)
{
    STREAM *s = (STREAM *)p;
    BYTE buf[2048];
    DWORD rnd = s->seed;
    while (s->done < s->total) {
        DWORD n, i, w;
        rnd = rnd * 1103515245u + 12345u;
        n = 1 + ((rnd >> 8) % 2048);
        if (n > s->total - s->done) n = (DWORD)(s->total - s->done);
        for (i = 0; i < n; i++) buf[i] = patternByte(s->done + i);
        w = writeAll(s->h, buf, n, 20000);
        if (w != n) { InterlockedIncrement(&s->bad); break; }
        s->done += n;
    }
    return 0;
}

static DWORD WINAPI readerThread(LPVOID p)
{
    STREAM *s = (STREAM *)p;
    BYTE buf[4096];
    while (s->done < s->total) {
        DWORD err, g = readSome(s->h, buf, sizeof(buf), 10000, &err), i;
        if (g == 0) { InterlockedIncrement(&s->bad); break; }
        for (i = 0; i < g; i++) if (buf[i] != patternByte(s->done + i)) { InterlockedIncrement(&s->bad); s->done = s->total; break; }
        if (s->done < s->total) s->done += g;
    }
    return 0;
}

static void testStream(void)
{
    enum { N = 4 };
    STREAM s[N];
    HANDLE th[N];
    DWORD64 t0, ms;
    const DWORD64 total = 2u * 1024 * 1024;
    int i, bad = 0;
    section("bulk streaming (2 MiB each way, full duplex, random chunk sizes)");
    resetBoth();
    memset(s, 0, sizeof(s));
    s[0].h = hA; s[0].total = total; s[0].seed = 1;      /* A writes */
    s[1].h = hB; s[1].total = total;                     /* B reads  */
    s[2].h = hB; s[2].total = total; s[2].seed = 2;      /* B writes */
    s[3].h = hA; s[3].total = total;                     /* A reads  */
    t0 = GetTickCount64();
    th[0] = CreateThread(NULL, 0, writerThread, &s[0], 0, NULL);
    th[1] = CreateThread(NULL, 0, readerThread, &s[1], 0, NULL);
    th[2] = CreateThread(NULL, 0, writerThread, &s[2], 0, NULL);
    th[3] = CreateThread(NULL, 0, readerThread, &s[3], 0, NULL);
    if (WaitForMultipleObjects(N, th, TRUE, 120000) != WAIT_OBJECT_0) { report("streams finished within 120 s", FALSE, "timeout"); return; }
    ms = GetTickCount64() - t0;
    for (i = 0; i < N; i++) { bad += s[i].bad; CloseHandle(th[i]); }
    report("4 MiB total delivered intact and in order", bad == 0 && s[1].done == total && s[3].done == total,
           "%d errors, %.1f MiB/s aggregate", bad, (double)(2 * total) / (1024.0 * 1024.0) / (ms ? ms / 1000.0 : 0.001));
    resetBoth();
}

static void testBuffers(void)
{
    COMSTAT st;
    DWORD errs = 0, i;
    section("buffer status / purge");
    resetBoth();
    writeAll(hA, "0123456789", 10, 2000);
    Sleep(100);
    memset(&st, 0, sizeof(st));
    ClearCommError(hB, &errs, &st);
    report("ClearCommError reports cbInQue == 10", st.cbInQue == 10, "cbInQue=%lu", st.cbInQue);
    PurgeComm(hB, PURGE_RXCLEAR);
    memset(&st, 0, sizeof(st));
    ClearCommError(hB, &errs, &st);
    report("PurgeComm(RXCLEAR) empties the queue", st.cbInQue == 0, "cbInQue=%lu", st.cbInQue);
    report("PurgeComm(TXABORT|TXCLEAR)", PurgeComm(hA, PURGE_TXABORT | PURGE_TXCLEAR), "err %lu", GetLastError());

    /* many tiny writes must keep their order */
    {
        BYTE b, prev = 0;
        DWORD ok = 1, rx;
        BYTE out[500];
        for (i = 0; i < 500; i++) { b = (BYTE)(i * 7 + 1); writeAll(hA, &b, 1, 2000); }
        rx = readExact(hB, out, 500, 2000);
        for (i = 0; i < 500; i++) if (out[i] != (BYTE)(i * 7 + 1)) { ok = 0; prev = out[i]; break; }
        report("500 one-byte writes arrive in order", rx == 500 && ok, "rx=%lu firstBad=%u", rx, prev);
    }
    resetBoth();
}

static void testModem(void)
{
    DWORD s;
    section("modem control lines (default wiring RTS->CTS, DTR->DSR)");
    resetBoth();
    EscapeCommFunction(hA, CLRRTS); EscapeCommFunction(hA, CLRDTR); Sleep(50);
    s = modem(hB);
    report("A low   -> B CTS/DSR low", !(s & MS_CTS_ON) && !(s & MS_DSR_ON), "status=0x%lX", s);
    EscapeCommFunction(hA, SETRTS); Sleep(50);
    s = modem(hB);
    report("A RTS   -> B CTS", (s & MS_CTS_ON) && !(s & MS_DSR_ON), "status=0x%lX", s);
    EscapeCommFunction(hA, SETDTR); Sleep(50);
    s = modem(hB);
    report("A DTR   -> B DSR", (s & MS_CTS_ON) && (s & MS_DSR_ON), "status=0x%lX", s);
    EscapeCommFunction(hB, CLRRTS); EscapeCommFunction(hB, CLRDTR); Sleep(50);
    s = modem(hA);
    report("B low   -> A CTS/DSR low", !(s & MS_CTS_ON) && !(s & MS_DSR_ON), "status=0x%lX", s);
    EscapeCommFunction(hB, SETRTS); EscapeCommFunction(hB, SETDTR); Sleep(50);
    s = modem(hA);
    report("B RTS+DTR -> A CTS+DSR", (s & MS_CTS_ON) && (s & MS_DSR_ON), "status=0x%lX", s);
}

static void testEvents(void)
{
    EVWAIT w;
    DWORD m;
    section("comm events (WaitCommEvent)");
    resetBoth();

    SetCommMask(hB, EV_RXCHAR);
    evStart(&w, hB);
    writeAll(hA, "x", 1, 1000);
    m = evFinish(&w, 2000);
    report("EV_RXCHAR on data arrival", (m & EV_RXCHAR) != 0, "mask=0x%lX", m);
    PurgeComm(hB, PURGE_RXCLEAR);

    EscapeCommFunction(hA, CLRRTS); Sleep(30);
    SetCommMask(hB, EV_CTS);
    evStart(&w, hB);
    EscapeCommFunction(hA, SETRTS);
    m = evFinish(&w, 2000);
    report("EV_CTS when peer raises RTS", (m & EV_CTS) != 0, "mask=0x%lX", m);

    EscapeCommFunction(hA, CLRDTR); Sleep(30);
    SetCommMask(hB, EV_DSR);
    evStart(&w, hB);
    EscapeCommFunction(hA, SETDTR);
    m = evFinish(&w, 2000);
    report("EV_DSR when peer raises DTR", (m & EV_DSR) != 0, "mask=0x%lX", m);

    SetCommMask(hB, EV_BREAK);
    evStart(&w, hB);
    EscapeCommFunction(hA, SETBREAK);
    m = evFinish(&w, 2000);
    EscapeCommFunction(hA, CLRBREAK);
    report("EV_BREAK when peer sends a break", (m & EV_BREAK) != 0, "mask=0x%lX", m);

    SetCommMask(hA, EV_TXEMPTY);
    evStart(&w, hA);
    writeAll(hA, "abcdefghij", 10, 1000);
    m = evFinish(&w, 2000);
    report("EV_TXEMPTY after a write drains", (m & EV_TXEMPTY) != 0, "mask=0x%lX", m);

    /* clearing the mask must release a pending WaitCommEvent */
    SetCommMask(hB, EV_RXCHAR);
    evStart(&w, hB);
    SetCommMask(hB, 0);
    m = WaitForSingleObject(w.ov.hEvent, 1000);
    report("SetCommMask(0) releases pending wait", m == WAIT_OBJECT_0, NULL);
    { DWORD n; GetOverlappedResult(hB, &w.ov, &n, FALSE); CloseHandle(w.ov.hEvent); }
    resetBoth();
}

static void testFlowControl(void)
{
    DCB d;
    PENDINGIO p;
    BYTE rx[64];
    COMSTAT st;
    DWORD errs, n;
    section("flow control");

    /* --- RTS/CTS: A honours CTS, which is driven by B's RTS --- */
    resetBoth();
    memset(&d, 0, sizeof(d)); d.DCBlength = sizeof(d);
    GetCommState(hB, &d); d.fRtsControl = RTS_CONTROL_DISABLE; SetCommState(hB, &d);
    EscapeCommFunction(hB, CLRRTS);
    GetCommState(hA, &d); d.fOutxCtsFlow = TRUE; SetCommState(hA, &d);
    Sleep(50);
    startWrite(hA, &p, 64);
    Sleep(400);
    memset(&st, 0, sizeof(st)); ClearCommError(hB, &errs, &st);
    report("CTS low: write is held back", WaitForSingleObject(p.ov.hEvent, 0) == WAIT_TIMEOUT && st.cbInQue == 0, "cbInQue=%lu", st.cbInQue);
    EscapeCommFunction(hB, SETRTS);
    report("CTS high: write completes", finishWrite(hA, &p, 2000), NULL);
    n = readExact(hB, rx, 64, 1000);
    report("... and all 64 bytes arrive", n == 64 && rx[0] == 1 && rx[63] == 64, "%lu bytes", n);

    /* --- XON/XOFF: A honours XOFF received from B --- */
    resetBoth();
    GetCommState(hA, &d); d.fOutX = TRUE; d.XonChar = 0x11; d.XoffChar = 0x13; SetCommState(hA, &d);
    writeAll(hB, "\x13", 1, 1000);
    Sleep(100);
    startWrite(hA, &p, 16);
    Sleep(400);
    memset(&st, 0, sizeof(st)); ClearCommError(hB, &errs, &st);
    report("XOFF received: write is held back", WaitForSingleObject(p.ov.hEvent, 0) == WAIT_TIMEOUT && st.cbInQue == 0, "cbInQue=%lu", st.cbInQue);
    writeAll(hB, "\x11", 1, 1000);
    report("XON received: write completes", finishWrite(hA, &p, 2000), NULL);
    n = readExact(hB, rx, 16, 1000);
    report("... and all 16 bytes arrive", n == 16, "%lu bytes", n);
    memset(&st, 0, sizeof(st)); ClearCommError(hA, &errs, &st);
    report("XON/XOFF bytes are consumed, not delivered", st.cbInQue == 0, "cbInQue=%lu", st.cbInQue);
    resetBoth();
}

static void testTimeouts(void)
{
    DWORD64 t0;
    DWORD ms, n, err;
    BYTE buf[16];
    section("read timeouts");
    resetBoth();

    setTimeouts(hB, 0, 0, 200);                       /* total timeout 200 ms */
    t0 = GetTickCount64();
    n = readSome(hB, buf, 10, 5000, &err);
    ms = (DWORD)(GetTickCount64() - t0);
    report("total timeout, no data: 0 bytes after ~200 ms", n == 0 && err == 0 && ms >= 150 && ms < 1500, "%lu bytes in %lu ms", n, ms);

    writeAll(hA, "abc", 3, 1000);
    t0 = GetTickCount64();
    n = readSome(hB, buf, 10, 5000, &err);
    ms = (DWORD)(GetTickCount64() - t0);
    report("total timeout, 3 of 10 bytes: returns 3 after ~200 ms", n == 3 && ms >= 150 && ms < 1500, "%lu bytes in %lu ms", n, ms);

    setTimeouts(hB, 100, 0, 0);                       /* interval timeout only */
    writeAll(hA, "abc", 3, 1000);
    t0 = GetTickCount64();
    n = readSome(hB, buf, 10, 5000, &err);
    ms = (DWORD)(GetTickCount64() - t0);
    report("interval timeout: returns 3 bytes after gap", n == 3 && ms < 1500, "%lu bytes in %lu ms", n, ms);

    setTimeouts(hB, MAXDWORD, 0, 0);                  /* return immediately */
    t0 = GetTickCount64();
    n = readSome(hB, buf, 10, 5000, &err);
    ms = (DWORD)(GetTickCount64() - t0);
    report("MAXDWORD interval: returns immediately", n == 0 && ms < 300, "%lu bytes in %lu ms", n, ms);
    resetBoth();
}

static void testCancelClose(void)
{
    OVERLAPPED ov;
    BYTE b;
    DWORD n = 0, e;
    HANDLE h2;
    int i, bad = 0;
    section("cancel / close semantics");
    resetBoth();

    setTimeouts(hB, 0, 0, 0);                         /* infinite: read stays pending */
    memset(&ov, 0, sizeof(ov)); ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    ReadFile(hB, &b, 1, &n, &ov);
    Sleep(100);
    CancelIoEx(hB, &ov);
    n = 0;
    GetOverlappedResult(hB, &ov, &n, TRUE);
    e = GetLastError();
    report("CancelIoEx aborts a pending read", e == ERROR_OPERATION_ABORTED, "error %lu", e);
    CloseHandle(ov.hEvent);

    /* close the handle while a read is pending; the driver must not hang or leak the port */
    setTimeouts(hB, 0, 0, 0);
    memset(&ov, 0, sizeof(ov)); ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    ReadFile(hB, &b, 1, &n, &ov);
    Sleep(50);
    CloseHandle(hB);
    Sleep(50);
    hB = openPort(nameB);
    report("close with pending read, then reopen", hB != INVALID_HANDLE_VALUE, "error %lu", GetLastError());
    CloseHandle(ov.hEvent);
    if (hB == INVALID_HANDLE_VALUE) { printf("cannot continue\n"); exit(2); }
    resetBoth();
    writeAll(hA, "z", 1, 1000);
    n = readExact(hB, &b, 1, 1000);
    report("data flows after reopen", n == 1 && b == 'z', NULL);

    for (i = 0; i < 300; i++) {
        BYTE c = (BYTE)i, r = 0;
        CloseHandle(hA); CloseHandle(hB);
        hA = openPort(nameA); hB = openPort(nameB);
        if (hA == INVALID_HANDLE_VALUE || hB == INVALID_HANDLE_VALUE) { bad++; break; }
        readAny(hB, 1000);
        writeAll(hA, &c, 1, 1000);
        if (readExact(hB, &r, 1, 1000) != 1 || r != c) bad++;
    }
    report("300 open/write/read/close cycles", bad == 0, "%d failures", bad);
    resetBoth();

    h2 = openPort("NoSuchPort99");
    e = GetLastError();
    report("opening a missing port fails with FILE_NOT_FOUND", h2 == INVALID_HANDLE_VALUE && e == ERROR_FILE_NOT_FOUND, "error %lu", e);
}

/*
 * Baud-rate emulation is timer based, so it is a good canary for architecture-specific timing bugs.
 * 960 bytes at 9600 baud 8N1 = 9600 bit times = 1.0 s. With EmuBR off the same transfer is near-instant.
 */
static void testBaudEmulation(BOOL expectEmulation)
{
    LARGE_INTEGER f, t0, t1;
    BYTE tx[960], rx[960];
    DWORD i, n;
    double sec;
    section(expectEmulation ? "baud-rate emulation (pair created with EmuBR=yes)" : "no baud-rate emulation (default pair)");
    resetBoth();
    setLine(hA, 9600, 8, NOPARITY, ONESTOPBIT);
    setLine(hB, 9600, 8, NOPARITY, ONESTOPBIT);
    for (i = 0; i < sizeof(tx); i++) tx[i] = (BYTE)(i * 3 + 1);
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    writeAll(hA, tx, sizeof(tx), 20000);
    n = readExact(hB, rx, sizeof(rx), 5000);
    QueryPerformanceCounter(&t1);
    sec = (double)(t1.QuadPart - t0.QuadPart) / (double)f.QuadPart;
    if (expectEmulation)
        report("960 bytes @ 9600 8N1 take about 1.0 s", n == sizeof(rx) && !memcmp(tx, rx, sizeof(tx)) && sec >= 0.85 && sec <= 1.6, "%lu bytes in %.3f s", n, sec);
    else
        report("960 bytes @ 9600 8N1 are delivered at once", n == sizeof(rx) && !memcmp(tx, rx, sizeof(tx)) && sec < 0.30, "%lu bytes in %.3f s", n, sec);
    resetBoth();
}

static const char *archName(void)
{
#if defined(_M_ARM64)
    return "arm64";
#elif defined(_M_X64)
    return "x64";
#elif defined(_M_IX86)
    return "x86";
#else
    return "?";
#endif
}

static void banner(void)
{
    typedef BOOL (WINAPI *PFN)(HANDLE, USHORT *, USHORT *);
    PFN f = (PFN)GetProcAddress(GetModuleHandleA("kernel32.dll"), "IsWow64Process2");
    USHORT proc = 0, nat = 0;
    const char *nn = "?";
    if (f && f(GetCurrentProcess(), &proc, &nat)) nn = nat == 0xAA64 ? "ARM64" : nat == 0x8664 ? "x64" : nat == 0x14C ? "x86" : "other";
    printf("c0ctest: process=%s on native=%s, ports %s <-> %s\n", archName(), nn, nameA, nameB);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: %s <portA> <portB>\n", argv[0]); return 64; }
    nameA = argv[1]; nameB = argv[2];
    banner();

    testOpen();
    testState();
    testBasicData();
    testBuffers();
    /* With baud-rate emulation on, 4 MiB would legitimately take minutes at 115200 baud. */
    if (argc > 3 && !_stricmp(argv[3], "emubr")) section("bulk streaming skipped: baud-rate emulation is on");
    else testStream();
    testModem();
    testEvents();
    testFlowControl();
    testTimeouts();
    testCancelClose();
    if (argc > 3) testBaudEmulation(!_stricmp(argv[3], "emubr"));

    CloseHandle(hA); CloseHandle(hB);
    printf("\nc0ctest (%s): %d passed, %d failed\n", archName(), g_pass, g_fail);
    return g_fail ? 1 : 0;
}
