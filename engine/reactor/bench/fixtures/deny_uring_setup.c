/* Execute the reactor test binary with only io_uring_setup denied. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_io_uring_setup, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog filter = {
        sizeof(instructions) / sizeof(instructions[0]), instructions,
    };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
        || prctl(PR_SET_SECCOMP, (unsigned long)SECCOMP_MODE_FILTER, &filter) != 0
        || setenv("FLINT_TEST_URING_DENIED", "1", 1) != 0)
    {
        perror("seccomp setup-denial fixture");
        return 1;
    }
    execv(argv[1], &argv[1]);
    perror("test entrypoint");
    return 1;
}
