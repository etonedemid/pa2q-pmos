/* Freestanding aarch64: configure a loop device atomically with backing fd,
 * 4K block size, and byte offset via LOOP_CONFIGURE, so a 4K-native ext4 image
 * at an offset inside a 4K disk mounts cleanly.
 * Usage: loopcfg /dev/block/loopN /dev/block/sdaX <offset> <blocksize>
 * Build: clang --target=aarch64-linux-gnu -static -nostdlib -ffreestanding -O2
 */
#define SYS_openat 56
#define SYS_ioctl  29
#define SYS_write  64
#define SYS_exit   93
#define AT_FDCWD   (-100)
#define O_RDWR     2
#define LOOP_CONFIGURE 0x4C0A   /* struct loop_config */

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
    while (*s >= '0' && *s <= '9') v = v * 10 + (unsigned)(*s++ - '0');
    return v;
}

/* loop_config is 304 bytes:
 *   [0]  u32 fd
 *   [4]  u32 block_size
 *   [8]  struct loop_info64 info (232 bytes)
 *          info.lo_offset is at info offset 24  -> config offset 32
 *   [240] u64 __reserved[8]
 */
int cmain(long argc, char **argv)
{
    unsigned char cfg[304];
    long i;

    if (argc < 5) { sc(SYS_write, 2, (long)"args\n", 5); return 2; }
    for (i = 0; i < 304; i++) cfg[i] = 0;

    long lf = sc(SYS_openat, AT_FDCWD, (long)argv[1], O_RDWR);
    if (lf < 0) { sc(SYS_write, 2, (long)"oL\n", 3); return 3; }
    long bf = sc(SYS_openat, AT_FDCWD, (long)argv[2], O_RDWR);
    if (bf < 0) { sc(SYS_write, 2, (long)"oB\n", 3); return 4; }

    unsigned long off = a2u(argv[3]);
    unsigned int bs = (unsigned int)a2u(argv[4]);

    *(unsigned int *)(cfg + 0) = (unsigned int)bf;   /* fd */
    *(unsigned int *)(cfg + 4) = bs;                 /* block_size */
    *(unsigned long *)(cfg + 32) = off;              /* info.lo_offset */
    *(unsigned int *)(cfg + 60) = 16;                /* info.lo_flags = LO_FLAGS_DIRECT_IO */

    long r = sc(SYS_ioctl, lf, LOOP_CONFIGURE, (long)cfg);
    if (r < 0) { sc(SYS_write, 2, (long)"cfg\n", 4); return 5; }
    sc(SYS_write, 1, (long)"OK\n", 3);
    return 0;
}

__asm__(
    ".global _start\n"
    "_start:\n"
    "  ldr x0, [sp]\n"
    "  add x1, sp, #8\n"
    "  bl cmain\n"
    "  mov x8, #93\n"
    "  svc #0\n"
);
