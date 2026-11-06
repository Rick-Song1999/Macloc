// LaunchShim.h —— launch_activate_socket(3) 的封装
//
// launchd 的「launch on demand socket」：
//   1) launchd 先把监听 socket 建好（不开进程）
//   2) 客户端一连上来，launchd 才拉起进程
//   3) 进程用 launch_activate_socket(3) 取回监听 fd
//
// 这函数在 libSystem 里，链接时自动带上。
//
// 注意：头文件里写的是 `int **fds`，但各版本 launchd 返回的数组布局有两种可能：
//   A) 扁平 int 数组          -> fds[0] 就是 fd
//   B) int* 指针数组           -> ((int**)fds)[0][0] 才是 fd
// 用 fstat 判一下哪个是 socket，运行时自适应，省得赌。
#ifndef MACLOC_LAUNCH_SHIM_H
#define MACLOC_LAUNCH_SHIM_H

#include <stddef.h>
#include <stdlib.h>
#include <sys/stat.h>

extern int launch_activate_socket(const char *name, int **fds, size_t *cnt);

/// 取回 launchd 托管的监听 fd；失败返回 -1
static inline int macloc_activate_socket(const char *name) {
    int *fds = NULL;
    size_t cnt = 0;
    if (launch_activate_socket(name, &fds, &cnt) != 0 || fds == NULL || cnt == 0) {
        return -1;
    }
    struct stat st;
    int fd = -1;
    if (fstat(fds[0], &st) == 0 && S_ISSOCK(st.st_mode)) {
        fd = fds[0];                       /* 布局 A：扁平 int 数组 */
    } else {
        int *inner = ((int **)fds)[0];     /* 布局 B：指针数组 */
        if (inner != NULL) fd = inner[0];
    }
    free(fds);
    return fd;
}

#endif /* MACLOC_LAUNCH_SHIM_H */
