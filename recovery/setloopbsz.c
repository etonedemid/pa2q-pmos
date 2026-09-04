/* Freestanding aarch64 helper: set a loop device's logical block size via
 * LOOP_SET_BLOCK_SIZE, so a 4K-native disk image mounts through the loop.
 * Usage: setloopbsz /dev/block/loopN 4096
 * No libc: raw syscalls only. Build: clang --target=aarch64-linux-gnu
 *   -static -nostdlib -ffreestanding -O2 setloopbsz.c -o setloopbsz
 */
#define SYS_openat 56
#define SYS_ioctl  29
#define SYS_write  64
#define SYS_exit   93
#define AT_FDCWD   (-100)
#define O_RDWR     2
#define LOOP_SET_BLOCK_SIZE 0x4C09

static long sc(long n, long a, long b, long c)
{
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    asm volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory", "cc");
    return x0;
}

static unsigned long a2u(const char *s)
{
    unsigned long v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return v;
}

int cmain(long argc, char **argv)
{
    if (argc < 3) { sc(SYS_write, 2, (long)"args\n", 5); return 2; }
    long fd = sc(SYS_openat, AT_FDCWD, (long)argv[1], O_RDWR);
    if (fd < 0) { sc(SYS_write, 2, (long)"open\n", 5); return 3; }
    long bs = (long)a2u(argv[2]);
    long r = sc(SYS_ioctl, fd, LOOP_SET_BLOCK_SIZE, bs);
    if (r < 0) { sc(SYS_write, 2, (long)"ioctl\n", 6); return 4; }
    sc(SYS_write, 1, (long)"OK\n", 3);
    return 0;
}

__asm__(
    ".global _start\n"
    "_start:\n"
    "  ldr x0, [sp]\n"       /* argc */
    "  add x1, sp, #8\n"     /* argv */
    "  bl cmain\n"
    "  mov x8, #93\n"        /* exit */
    "  svc #0\n"
);
